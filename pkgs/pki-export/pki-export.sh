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

Exit 0: nothing changed, or a PR exists/was opened for this exact set of
certificates. Exit 1: an error, or a node was skipped (see the log).
EOF
}

die() { echo "pki-export: error: $*" >&2; exit 1; }
log() { echo "pki-export: $*" >&2; }

namespace=cluster-pki
label=pki.neurosis/node
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

# ---------------------------------------------------------------- the leaves
# -> $work/secrets.json: [{name, node, crt, key}] (crt/key base64, as in the
# Secret), sorted by name.
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
  jq --arg ns "$namespace" --arg l "$label" '
    [ .[]
      | select(.kind == "Secret" and (.metadata.namespace // $ns) == $ns
               and (.metadata.labels[$l] // "") != "")
      | { name: .metadata.name, node: .metadata.labels[$l],
          type: (.type // ""),
          crt: (.data["tls.crt"] // ""), key: (.data["tls.key"] // "") } ]
    | sort_by(.name)' "$raw" > "$work/secrets.json"
}

# ---------------------------------------------------------------- certs
leaf_fp() { # PEM file -> SHA-256 fingerprint of its first cert (AA:BB:...)
  openssl x509 -noout -fingerprint -sha256 -in "$1" | sed 's/^[^=]*=//'
}
leaf_subject() { openssl x509 -noout -subject -nameopt RFC2253 -in "$1" | sed 's/^subject=//'; }
leaf_notafter() { openssl x509 -noout -enddate -in "$1" | sed 's/^notAfter=//'; }

# Stage every Secret as $work/new/<node>/<stem>.pem and <stem>-key.pem, after
# checking it: kubernetes.io/tls, both keys present, name ends in -<node>,
# the key matches the cert, the cert is not expired.
stage_secrets() {
  local n i name node type crt key dir
  n=$(jq length "$work/secrets.json")
  [ "$n" -gt 0 ] || die "no Secrets labelled $label in namespace $namespace"
  for ((i = 0; i < n; i++)); do
    IFS=$'\t' read -r name node type < <(jq -r --argjson i "$i" \
      '.[$i] | [.name, .node, .type] | @tsv' "$work/secrets.json")
    [[ $node =~ ^[a-z0-9]+$ ]] || die "Secret $name: bad node label '$node'"
    [[ $name =~ ^[a-z0-9-]+-$node$ ]] \
      || die "Secret $name: name must be <component>-$node"
    [ "$type" = kubernetes.io/tls ] || die "Secret $name: type '$type', want kubernetes.io/tls"
    dir=$work/new/$node
    mkdir -p "$dir"
    crt=$dir/$name.pem
    key=$dir/$name-key.pem
    jq -r --argjson i "$i" '.[$i].crt' "$work/secrets.json" | base64 -d > "$crt"
    jq -r --argjson i "$i" '.[$i].key' "$work/secrets.json" | base64 -d > "$key"
    [ -s "$crt" ] && [ -s "$key" ] || die "Secret $name: tls.crt or tls.key is empty"
    openssl x509 -noout -in "$crt" 2>/dev/null || die "Secret $name: tls.crt is not a certificate"
    [ "$(openssl x509 -noout -pubkey -in "$crt" | openssl sha256)" \
      = "$(openssl pkey -pubout -in "$key" 2>/dev/null | openssl sha256)" ] \
      || die "Secret $name: tls.key does not match tls.crt"
    openssl x509 -noout -checkend 0 -in "$crt" >/dev/null \
      || die "Secret $name: certificate has expired"
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
    -c 'credential.helper=!f() { echo username=x-access-token; echo "password=$GITHUB_TOKEN"; }; f' \
    "$@"
}

# ---------------------------------------------------------------- main
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

# Which nodes changed? Compare leaf fingerprints with the base tree.
changed=()
skipped=0
for d in "$work/new"/*/; do
  node=$(basename "$d")
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
# A node with a file on $base but no Secrets at all.
if [ -d "$tree/secrets/pki" ]; then
  for f in "$tree/secrets/pki"/*.yaml; do
    [ -e "$f" ] || continue
    node=$(basename "$f" .yaml)
    if [ ! -d "$work/new/$node" ]; then
      log "SKIP $node: secrets/pki/$node.yaml is on $base but the cluster has no Secrets for it"
      skipped=1
    fi
  done
fi

if [ ${#changed[@]} -eq 0 ]; then
  log "no change: every certificate matches $base"
  exit "$skipped"
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
  exit "$skipped"
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
    exit "$skipped"
  fi
  if [ -n "$closed_pr" ]; then
    log "this set was proposed in $closed_pr and closed; not reopening (delete branch $existing to propose it again)"
    exit "$skipped"
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
exit "$skipped"
