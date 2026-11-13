# pki-export: copy the host leaves cert-manager issued in `cluster-pki` into
# git as sops files and open a PR (docs/pki-migration-plan.md, phase 2, P2).
# Packaged by ./default.nix (writeShellApplication: bash, set -euo pipefail,
# runtimeInputs on PATH); runs daily as the CronJob in
# k8s/components/infra/cluster-pki/export.nix.
#
# Per node (Secret label pki.neurosis/node) it writes secrets/pki/<node>.yaml:
# a flat map whose keys are the file names in /var/lib/kubernetes/secrets,
#   <stem>.pem       tls.crt (leaf + intermediate), plaintext
#   <stem>-key.pem   tls.key, sops-encrypted
# where <stem> is the Secret's name (== the Certificate's name).
#
# It never decrypts anything and holds no private age key: the files are
# encrypted from scratch with the public recipients in .sops.yaml at `main`
# (creation rule for secrets/pki/<node>.yaml). sops cannot edit a file
# without the data key, so a changed node's file is regenerated whole, and an
# unchanged node's file is left alone (re-encrypting would churn it).
#
# Checks, before anything is encrypted or pushed (there is no separate CI
# checker for these files; this job is it):
#   per node, or the node is skipped (never a partial file) and the run
#   exits 1:
#     - completeness: every expected leaf (--secrets / PKI_EXPORT_SECRETS,
#       the names from k8s/components/infra/cluster-pki/leaves.nix) is
#       there, and nothing unexpected is
#     - chain: the leaf verifies (openssl verify -partial_chain) against its
#       own intermediate, cluster/pki/{k8s,etcd,front-proxy}-ca.pem on main,
#       and against no other CA there (the other two, root-ca.pem,
#       workload-ca.pem); any further cert in tls.crt is that intermediate;
#       the leaf is not a CA
#     - ownership: <stem> ends in -<node>; kubelet-<node> has CN
#       system:node:<node>, etcd-{peer,server}-<node> CN <node>; neither the
#       CN nor a DNS SAN names another node
#     - the key matches the cert, the cert is not expired
#   on every run: no cert in main's secrets/pki/*.yaml expires within 14
#   days, or the run exits 1 (after opening a renewal PR, if any), so a
#   failing CronJob flags an unmerged renewal.

usage() {
  cat <<'EOF'
pki-export [options]

Source of the leaves (one of):
  (default)            kubectl get secrets -n NAMESPACE -l pki.neurosis/node
                       (needs `list` on Secrets)
  --secrets "A B ..."  kubectl get secrets -n NAMESPACE A B ... instead
                       (needs only `get` on those names; default:
                       $PKI_EXPORT_SECRETS). Missing ones are skipped.
  --from-dir DIR       *.yaml files in DIR holding Secrets or Lists of them
                       (tests; no cluster needed)
  --namespace NS       default: cluster-pki

Repository:
  --repo URL           git URL to clone (--depth 1) and push to; default
                       https://github.com/$GITHUB_REPOSITORY.git
  --github-repo O/R    default: $GITHUB_REPOSITORY or charlie-horse/flake
  --base BRANCH        default: main
  --token-file FILE    GitHub token (fine-grained: Contents + Pull requests
                       read/write on this repo); default
                       $PKI_EXPORT_TOKEN_FILE or
                       /var/run/secrets/pki-export-github/token

Dry run (no git and no API calls at all):
  --dry-run            write the changed secrets/pki/<node>.yaml files and
                       pr-body.md to --out instead of committing
  --repo-dir DIR       checkout to read .sops.yaml and the current
                       secrets/pki files from (default: .)
  --out DIR            default: ./pki-export-out

--secrets is also the completeness list and is required (with --from-dir
it only names the leaves that must be there).

Exit 0: nothing changed, or a PR exists/was opened for this exact set of
certificates. Exit 1: an error, a node was skipped, or a cert on main
expires within 14 days (see the log).
EOF
}

die() { echo "pki-export: error: $*" >&2; exit 1; }
log() { echo "pki-export: $*" >&2; }

namespace=cluster-pki
label=pki.neurosis/node
ca_label=pki.neurosis/ca
expiry_days=14
from_dir=
secret_names=${PKI_EXPORT_SECRETS:-}
dry_run=0
repo_dir=.
out=./pki-export-out
github_repo=${GITHUB_REPOSITORY:-charlie-horse/flake}
repo=
base=main
token_file=${PKI_EXPORT_TOKEN_FILE:-/var/run/secrets/pki-export-github/token}
api=${GITHUB_API_URL:-https://api.github.com}

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --from-dir) from_dir=$2; shift 2 ;;
    --secrets) secret_names=$2; shift 2 ;;
    --namespace) namespace=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    --github-repo) github_repo=$2; shift 2 ;;
    --base) base=$2; shift 2 ;;
    --token-file) token_file=$2; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --repo-dir) repo_dir=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
: "${repo:=https://github.com/$github_repo.git}"
[[ $github_repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || die "bad --github-repo '$github_repo'"
[[ $base =~ ^[A-Za-z0-9_./-]+$ ]] || die "bad --base '$base'"

# Nothing here may decrypt: make sure no age identity is picked up from the
# environment (the pod has none; this guards a run on an admin machine).
unset SOPS_AGE_KEY SOPS_AGE_KEY_FILE SOPS_AGE_KEY_CMD SOPS_AGE_SSH_PRIVATE_KEY_FILE
export SOPS_AGE_KEY_FILE=/dev/null

# Private keys pass through here in plaintext: keep the work dir private
# (in the pod it is a memory-backed emptyDir at $TMPDIR).
export LC_ALL=C
umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/pki-export.XXXXXX")
trap 'rm -rf "$work"' EXIT

# Final exit status: 1 if a node was skipped or a cert on main is expiring.
skipped=0
expiring=()
finish() {
  local e
  for e in "${expiring[@]}"; do
    log "EXPIRING within $expiry_days days on $base: $e"
  done
  if [ ${#expiring[@]} -gt 0 ] || [ "$skipped" = 1 ]; then exit 1; fi
  exit 0
}

# ---------------------------------------------------------------- the leaves
# -> $work/secrets.tsv: name, node, ca label, type, tls.crt, tls.key (base64,
# as in the Secret), one line per labelled Secret, sorted by name (one jq
# pass).
fetch_secrets() {
  local raw=$work/secrets-raw.json
  if [ -n "$from_dir" ]; then
    [ -d "$from_dir" ] || die "--from-dir: not a directory: '$from_dir'"
    local f files=()
    for f in "$from_dir"/*.yaml "$from_dir"/*.yml; do
      [ -e "$f" ] && files+=("$f")
    done
    [ ${#files[@]} -gt 0 ] || die "--from-dir: no *.yaml files in '$from_dir'"
    # Each document: a Secret, or a List of Secrets.
    yq ea -o=json -I=0 '[.] | .[]' "${files[@]}" \
      | jq -s '[ .[] | if .kind == "List" then .items[] else . end ]' > "$raw"
  elif [ -n "$secret_names" ]; then
    # By name: the CronJob's Role grants `get` on exactly these
    # (resourceNames), so the CA Secrets in the namespace stay unreadable.
    local names
    read -r -a names <<<"$secret_names"
    kubectl get secrets -n "$namespace" --ignore-not-found -o json "${names[@]}" \
      | jq -s '[ .[] | if .kind == "List" then .items[] else . end ]' > "$raw"
  else
    kubectl get secrets -n "$namespace" -l "$label" -o json \
      | jq '.items' > "$raw"
  fi
  jq --arg ns "$namespace" --arg l "$label" --arg c "$ca_label" -r '
    [ .[]
      | select(.kind == "Secret" and (.metadata.namespace // $ns) == $ns
               and (.metadata.labels[$l] // "") != "")
      | [ .metadata.name, .metadata.labels[$l], (.metadata.labels[$c] // ""),
          (.type // ""), (.data["tls.crt"] // ""), (.data["tls.key"] // "") ]
        # `read` merges empty tab-separated fields: never leave one empty
        | map(if . == "" then "-" else . end) ]
    | sort_by(.[0]) | .[] | @tsv' "$raw" > "$work/secrets.tsv"
}

# ---------------------------------------------------------------- certs
leaf_fp() { # PEM file -> SHA-256 fingerprint of its first cert (AA:BB:...)
  openssl x509 -noout -fingerprint -sha256 -in "$1" | sed 's/^[^=]*=//'
}
leaf_subject() { openssl x509 -noout -subject -nameopt RFC2253 -in "$1" | sed 's/^subject=//'; }
leaf_notafter() { openssl x509 -noout -enddate -in "$1" | sed 's/^notAfter=//'; }

# The intermediate a component's leaves come from (cluster-pki.sh SPECS).
ca_of() {
  case "$1" in
    etcd-peer | etcd-server | etcd-client-apiserver) echo etcd ;;
    front-proxy-client) echo front-proxy ;;
    *) echo k8s ;;
  esac
}

bad() { # node message: reject the node (it is skipped, the run exits 1)
  log "REJECT $1: $2"
  touch "$work/bad-$1"
}

# Decode every Secret to $work/new/<node>/<stem>.pem and <stem>-key.pem and
# note "<stem> <ca label> <type>" in $work/meta-<node>. check_node checks.
stage_secrets() {
  local name node ca type crt key dir
  [ -s "$work/secrets.tsv" ] || die "no Secrets labelled $label in namespace $namespace"
  while IFS=$'\t' read -r name node ca type crt key; do
    if ! [[ $node =~ ^[a-z0-9]+$ ]]; then
      log "REJECT Secret $name: bad node label '$node'"
      skipped=1
      continue
    fi
    dir=$work/new/$node
    mkdir -p "$dir"
    echo "$name $ca $type" >> "$work/meta-$node"
    base64 -d <<<"$crt" > "$dir/$name.pem" 2>/dev/null || : > "$dir/$name.pem"
    base64 -d <<<"$key" > "$dir/$name-key.pem" 2>/dev/null || : > "$dir/$name-key.pem"
  done < "$work/secrets.tsv"
}

# Every check of one node's staged leaves; any failure marks the node bad.
check_node() {
  local node=$1 name lca type comp ca crt key d n other cn want f i sans
  local cas=(k8s etcd front-proxy)
  # Completeness: every expected leaf of this node is there.
  for name in "${expected[@]}"; do
    [[ $name == *-"$node" ]] || continue
    [ -f "$work/new/$node/$name.pem" ] || bad "$node" "$name: expected, not in the cluster"
  done
  while read -r name lca type; do
    [ "$lca" = - ] && lca=
    crt=$work/new/$node/$name.pem
    key=$work/new/$node/$name-key.pem
    if ! [[ $name =~ ^[a-z0-9-]+-$node$ ]]; then
      bad "$node" "$name: name must be <component>-$node"
      continue
    fi
    [[ " ${expected[*]} " == *" $name "* ]] || { bad "$node" "$name: not an expected leaf"; continue; }
    [ "$type" = kubernetes.io/tls ] || { bad "$node" "$name: type '$type', want kubernetes.io/tls"; continue; }
    [ -s "$crt" ] && [ -s "$key" ] || { bad "$node" "$name: tls.crt or tls.key is empty"; continue; }
    d=$work/split/$node/$name
    mkdir -p "$d"
    if ! (cd "$d" && csplit -s -z -f c "$crt" '/-----BEGIN CERTIFICATE-----/' '{*}') 2>/dev/null \
      || ! openssl x509 -noout -in "$d/c00" 2>/dev/null; then
      bad "$node" "$name: tls.crt is not a certificate"
      continue
    fi
    # The key matches the cert; not expired; not a CA.
    [ "$(openssl x509 -noout -pubkey -in "$d/c00" | openssl sha256)" \
      = "$(openssl pkey -pubout -in "$key" 2>/dev/null | openssl sha256)" ] \
      || { bad "$node" "$name: tls.key does not match tls.crt"; continue; }
    openssl x509 -noout -checkend 0 -in "$d/c00" >/dev/null \
      || { bad "$node" "$name: certificate has expired"; continue; }
    if openssl x509 -noout -ext basicConstraints -in "$d/c00" 2>/dev/null | grep -q 'CA:TRUE'; then
      bad "$node" "$name: the leaf is a CA"
      continue
    fi
    # Chain: its own intermediate, and no other CA.
    comp=${name%-"$node"}
    ca=$(ca_of "$comp")
    if [ -n "$lca" ] && [ "$lca" != "$ca" ]; then
      bad "$node" "$name: label $ca_label=$lca, want $ca"
      continue
    fi
    f=$tree/cluster/pki/$ca-ca.pem
    [ -s "$f" ] || die "no $f on $base"
    openssl verify -partial_chain -CAfile "$f" "$d/c00" >/dev/null 2>&1 \
      || { bad "$node" "$name: does not verify against cluster/pki/$ca-ca.pem"; continue; }
    for other in "${cas[@]}" root workload; do
      [ "$other" = "$ca" ] && continue
      f=$tree/cluster/pki/$other-ca.pem
      [ -s "$f" ] || continue
      if openssl verify -partial_chain -CAfile "$f" "$d/c00" >/dev/null 2>&1; then
        bad "$node" "$name: also verifies against cluster/pki/$other-ca.pem"
        continue 2
      fi
    done
    want=$(openssl x509 -noout -fingerprint -sha256 -in "$tree/cluster/pki/$ca-ca.pem")
    for ((i = 1; ; i++)); do
      printf -v n '%s/c%02d' "$d" "$i"
      [ -f "$n" ] || break
      [ "$(openssl x509 -noout -fingerprint -sha256 -in "$n" 2>/dev/null)" = "$want" ] \
        || { bad "$node" "$name: chain cert $i is not cluster/pki/$ca-ca.pem"; continue 2; }
    done
    # Ownership: CN and DNS SANs.
    cn=$(openssl x509 -noout -subject -nameopt RFC2253 -in "$d/c00" \
      | sed -n 's/^subject=\(.*,\)\{0,1\}CN=\([^,]*\).*/\2/p')
    case "$comp" in
      kubelet) want=system:node:$node ;;
      etcd-peer | etcd-server) want=$node ;;
      *) want= ;;
    esac
    if [ -n "$want" ] && [ "$cn" != "$want" ]; then
      bad "$node" "$name: CN '$cn', want '$want'"
      continue
    fi
    sans=$(openssl x509 -noout -ext subjectAltName -in "$d/c00" 2>/dev/null \
      | tail -n +2 | tr ',' '\n' | sed -n 's/^ *DNS://p')
    for other in "${nodes[@]}"; do
      [ "$other" = "$node" ] && continue
      if grep -qE "^$other(\.|$)" <<<"$sans" || [[ $cn == "$other" || $cn == *":$other" ]]; then
        bad "$node" "$name: names another node ($other)"
        continue 2
      fi
    done
  done < "$work/meta-$node"
}

# Every cert in the base tree's secrets/pki/*.yaml must outlive
# $expiry_days days; the run fails otherwise (finish).
check_expiry() {
  local file k d c
  for file in "$tree/secrets/pki"/*.yaml; do
    [ -e "$file" ] || continue
    while IFS= read -r k; do
      d=$work/exp/${file##*/}/$k
      mkdir -p "$d"
      K=$k yq -r '.[strenv(K)]' "$file" > "$d/all.pem"
      (cd "$d" && csplit -s -z -f c all.pem '/-----BEGIN CERTIFICATE-----/' '{*}') 2>/dev/null || true
      for c in "$d"/c[0-9]*; do
        [ -f "$c" ] || continue
        openssl x509 -noout -checkend $((expiry_days * 86400)) -in "$c" >/dev/null 2>&1 \
          || expiring+=("secrets/pki/${file##*/} $k: $(leaf_subject "$c"), not after $(leaf_notafter "$c")")
      done
    done < <(yq -r 'keys | .[] | select(test("\.pem$") and (test("-key\.pem$") | not))' "$file")
  done
}

# "<file> <fp>" for every cert of a node in the new set / in the base tree.
new_fps() {
  local f
  for f in "$work/new/$1"/*.pem; do
    case "$f" in *-key.pem) continue ;; esac
    echo "${f##*/} $(leaf_fp "$f")"
  done | sort
}
base_fps() {
  local file=$tree/secrets/pki/$1.yaml k
  [ -f "$file" ] || return 0
  # Certs are plaintext in these files; never touch the -key.pem values.
  while IFS= read -r k; do
    K=$k yq -r '.[strenv(K)]' "$file" > "$work/base.pem"
    echo "$k $(leaf_fp "$work/base.pem")"
  done < <(yq -r 'keys | .[] | select(test("\.pem$") and (test("-key\.pem$") | not))' "$file") \
    | sort
}

# Build the flat map and encrypt it with the public recipients only.
encrypt_node() {
  local node=$1 dest=$2 f plain=$work/plain-$1.yaml
  echo '{}' > "$plain"
  for f in "$work/new/$node"/*.pem; do
    K=${f##*/} V=$(cat "$f") yq -i '.[strenv(K)] = strenv(V)' "$plain"
  done
  yq -i 'sort_keys(.)' "$plain"
  mkdir -p "${dest%/*}"
  (cd "$tree" && sops --encrypt --config .sops.yaml \
    --filename-override "secrets/pki/$node.yaml" \
    --input-type yaml --output-type yaml "$plain") > "$dest.tmp" \
    || { rm -f "$dest.tmp"; die "sops --encrypt for $node failed (is there a .sops.yaml rule for secrets/pki/$node.yaml on $base?)"; }
  rm -f "$plain"
  # Self-check: every -key.pem value encrypted, every cert in the clear.
  yq -e '[to_entries[] | select(.key != "sops")
          | select((.key | test("-key\.pem$")) != (.value | test("^ENC\[")))]
         | length == 0' "$dest.tmp" >/dev/null \
    || { rm -f "$dest.tmp"; die "$node: encryption check failed (keys must be ENC[...], certs plaintext)"; }
  mv "$dest.tmp" "$dest"
}

# ---------------------------------------------------------------- GitHub API
api_call() { # METHOD PATH [JSON-BODY-FILE] -> body on stdout
  local method=$1 path=$2 data=${3:-}
  local args=(-fsS --retry 3 -X "$method"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28")
  [ -n "$data" ] && args+=(-H "Content-Type: application/json" --data-binary "@$data")
  # The token goes in on stdin (curl -K -), never on the command line.
  printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" \
    | curl -K - "${args[@]}" "$api$path"
}
git_auth() { # git with the token from $GITHUB_TOKEN via a credential helper
  # shellcheck disable=SC2016 # expanded by git's helper shell, not here
  git -c credential.helper= \
    -c 'credential.helper=!f() { echo username=x-access-token; printf "%s=%s\n" password "$GITHUB_TOKEN"; }; f' \
    "$@"
}

# ---------------------------------------------------------------- main
# Expected leaves and the nodes they name.
read -r -a expected <<<"$secret_names"
[ ${#expected[@]} -gt 0 ] || die "no expected leaves: pass --secrets (PKI_EXPORT_SECRETS)"
mapfile -t nodes < <(printf '%s\n' "${expected[@]}" | sed 's/.*-//' | sort -u)

fetch_secrets
stage_secrets

if [ "$dry_run" = 1 ]; then
  tree=$repo_dir
  [ -f "$tree/.sops.yaml" ] || die "--repo-dir '$tree' has no .sops.yaml"
  log "dry run: reading $tree, writing to $out (no git, no API)"
else
  [ -r "$token_file" ] || die "token file not readable: '$token_file'"
  GITHUB_TOKEN=$(tr -d '\r\n' < "$token_file")
  export GITHUB_TOKEN
  [ -n "$GITHUB_TOKEN" ] || die "token file '$token_file' is empty"
  tree=$work/repo
  log "cloning $repo ($base, depth 1)"
  git_auth clone -q --depth 1 --single-branch --branch "$base" "$repo" "$tree"
fi

check_expiry

# Check every node, then compare leaf fingerprints with the base tree.
changed=()
for node in "${nodes[@]}"; do
  if [ ! -d "$work/new/$node" ]; then
    log "SKIP $node: the cluster has none of its leaves"
    skipped=1
    continue
  fi
  check_node "$node"
  if [ -e "$work/bad-$node" ]; then
    log "SKIP $node: failed the checks above; nothing proposed for it"
    skipped=1
    continue
  fi
  new_fps "$node" > "$work/fp-new-$node"
  base_fps "$node" > "$work/fp-base-$node"
  # A cert on $base that the cluster no longer has: refuse to drop it.
  missing=$(join -v 2 <(cut -d' ' -f1 "$work/fp-new-$node") \
    <(cut -d' ' -f1 "$work/fp-base-$node") || true)
  if [ -n "$missing" ]; then
    log "SKIP $node: on $base but not in the cluster: $(echo "$missing" | tr '\n' ' ')"
    skipped=1
    continue
  fi
  if cmp -s "$work/fp-new-$node" "$work/fp-base-$node"; then
    log "$node: no change"
  else
    changed+=("$node")
  fi
done
# Secrets of a node that no expected leaf names.
for d in "$work/new"/*/; do
  [ -d "$d" ] || continue
  node=$(basename "$d")
  if ! printf '%s\n' "${nodes[@]}" | grep -qxF "$node"; then
    log "REJECT $node: Secrets for a node with no expected leaves: $(cut -d' ' -f1 "$work/meta-$node" | tr '\n' ' ')"
    skipped=1
  fi
done

if [ ${#changed[@]} -eq 0 ]; then
  log "no change: every certificate matches $base"
  finish
fi

# The proposal's identity: a hash of every cert fingerprint it carries.
digest=$(for node in "${changed[@]}"; do sed "s|^|$node/|" "$work/fp-new-$node"; done \
  | sha256sum | cut -c1-12)
date=$(date -u +%Y-%m-%d)
branch=pki-renew/$date-$digest
log "changed: ${changed[*]} (set $digest)"

# PR body: one row per changed cert.
body=$work/pr-body.md
{
  echo "Certificates renewed by cert-manager in \`$namespace\`, exported by pki-export."
  echo "Only the \`-key.pem\` values are encrypted (recipients: admins + that host)."
  echo
  echo "| Node | File | Subject | Not after | SHA-256 |"
  echo "| --- | --- | --- | --- | --- |"
  for node in "${changed[@]}"; do
    while read -r file fp; do
      grep -qxF "$file $fp" "$work/fp-base-$node" && continue
      c=$work/new/$node/$file
      echo "| $node | \`$file\` | \`$(leaf_subject "$c")\` | $(leaf_notafter "$c") | \`$fp\` |"
    done < "$work/fp-new-$node"
  done
  echo
  echo "After merge, on each host listed: \`cd /etc/nixos && git pull && sudo nixos-rebuild switch --flake /etc/nixos#<host>\`."
  echo
  echo "<!-- pki-export set=$digest -->"
} > "$body"

if [ "$dry_run" = 1 ]; then
  mkdir -p "$out"
  for node in "${changed[@]}"; do
    encrypt_node "$node" "$out/secrets/pki/$node.yaml"
    log "wrote $out/secrets/pki/$node.yaml"
  done
  cp "$body" "$out/pr-body.md"
  log "would push $branch and open a PR (body: $out/pr-body.md)"
  finish
fi

# Already proposed? A branch for this exact set (any date) means a PR exists,
# existed, or failed to open last time.
owner=${github_repo%%/*}
existing=$(git_auth -C "$tree" ls-remote --heads origin "refs/heads/pki-renew/*-$digest" \
  | sed 's|.*refs/heads/||' | head -n1)
if [ -n "$existing" ]; then
  prs=$(api_call GET "/repos/$github_repo/pulls?state=all&head=$owner:$existing&per_page=10")
  open_pr=$(jq -r '[.[] | select(.state == "open")][0].html_url // empty' <<<"$prs")
  closed_pr=$(jq -r '[.[] | select(.state == "closed")][0].html_url // empty' <<<"$prs")
  if [ -n "$open_pr" ]; then
    log "no change: this set is already proposed in $open_pr"
    finish
  fi
  if [ -n "$closed_pr" ]; then
    log "this set was proposed in $closed_pr and closed; not reopening (delete branch $existing to propose it again)"
    finish
  fi
  log "branch $existing exists without a PR; opening one"
  branch=$existing
else
  git -C "$tree" switch -q -c "$branch"
  for node in "${changed[@]}"; do
    encrypt_node "$node" "$tree/secrets/pki/$node.yaml"
  done
  git -C "$tree" add secrets/pki
  git -C "$tree" \
    -c user.name="${GIT_AUTHOR_NAME:-pki-export}" \
    -c user.email="${GIT_AUTHOR_EMAIL:-pki-export@users.noreply.github.com}" \
    commit -q -m "pki: renewed host certificates (${changed[*]})" \
    -m "Exported from cert-manager (namespace $namespace) by pki-export; set $digest."
  git_auth -C "$tree" push -q origin "HEAD:refs/heads/$branch"
  log "pushed $branch"
fi

# Older open pki-renew PRs are superseded by this one (left for a human).
others=$(api_call GET "/repos/$github_repo/pulls?state=open&per_page=100" \
  | jq -r '.[] | select(.head.ref | startswith("pki-renew/")) | "#\(.number)"' | tr '\n' ' ')
if [ -n "$others" ]; then
  printf '\nSupersedes (close after merging this): %s\n' "$others" >> "$body"
fi

jq -n --arg t "pki: renewed host certificates (${changed[*]})" \
  --arg h "$branch" --arg b "$base" --rawfile body "$body" \
  '{title: $t, head: $h, base: $b, body: $body, maintainer_can_modify: true}' > "$work/pr.json"
url=$(api_call POST "/repos/$github_repo/pulls" "$work/pr.json" | jq -r .html_url)
log "opened $url"
finish
