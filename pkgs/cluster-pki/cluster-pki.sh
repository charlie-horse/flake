# cluster-pki: generate and rotate the cluster PKI from cluster/definition.nix.
#
# Prepended by default.nix:
#   CLUSTER_PKI_DEFINITION  JSON projection of cluster/definition.nix (store path)
#   CLUSTER_PKI_ROOT_CA     cluster/pki/root-ca.pem as a store path, or empty
#                           while the offline root does not exist yet
#
# Layout of the output dir (default
# ${XDG_DATA_HOME:-~/.local/share}/cluster-pki/<cluster>, operator machine only):
#   ca/<k8s|etcd|front-proxy>/current/{ca.pem,ca-key.pem}   signing CA
#   ca/<ca>/next/        new CA during a rotation (after `begin`); with an
#                        offline root: ca-key.pem + ca.csr from --ca-csr,
#                        ca.pem from --ca-import, and .pending until `begin`
#   ca/<ca>/previous/    old CA during a rotation (after `reissue`)
#   ca/<ca>/trust/*.pem  extra trusted certs (e.g. adopted legacy CA, public)
#   ca/<ca>/retired/<ts>/  CAs dropped by `finish`/`abort` (never deleted)
#   ca.pem etcd-ca.pem front-proxy-ca.pem   trust bundles (what nodes get)
#   ca-key.pem etcd-ca-key.pem front-proxy-ca-key.pem  -> symlinks to signers
#   sa.key sa.pub                           service-account keypair
#   <component>-<node>.pem / <component>-<node>-key.pem   leaves
#   backup/<ts>/         leaves replaced by a re-issue
#
# The NixOS side reads every file from /var/lib/kubernetes/secrets/<same name>.

set -euo pipefail
umask 077

CA_HOURS=${CLUSTER_PKI_CA_HOURS:-87600}     # 10 years
LEAF_HOURS=${CLUSTER_PKI_LEAF_HOURS:-8760}  # 1 year
RENEW_BEFORE_DAYS=${CLUSTER_PKI_RENEW_BEFORE_DAYS:-30}
KEY_ALGO=rsa
KEY_SIZE=2048

# Where the offline root's public cert lives in this repo (docs/pki.md).
# default.nix bakes it into CLUSTER_PKI_ROOT_CA when the file exists.
ROOT_CA_REPO_PATH=cluster/pki/root-ca.pem

out=
def=${CLUSTER_PKI_DEFINITION:-}
root_ca=${CLUSTER_PKI_ROOT_CA:-}
self_signed=0
csr_ca=
import_ca=
import_file=
mode=generate
renew=0
only_node=
rotate_ca=
phase=begin
trust_ca=
trust_file=
deploy_node=
deploy_host=
staging=cluster-pki-staging
dry_run=0
ts=$(date -u +%Y%m%dT%H%M%SZ)

usage() {
  cat <<'EOF'
Common options: [--out DIR] [--definition FILE.json] [--root-ca FILE.pem]
    --out      default ${XDG_DATA_HOME:-~/.local/share}/cluster-pki/<cluster>
    --root-ca  the offline root's public cert (default: cluster/pki/root-ca.pem
               baked in at build time, if it exists in the repo)

cluster-pki [--renew] [--node NAME] [--self-signed]
    Create missing CAs, the SA keypair and every node's leaves. Idempotent:
    CA keys are never overwritten; a leaf is (re)issued only when missing,
    not signed by the current CA, its SANs/subject/chain differ from the
    definition, it expires within 30 days, or --renew is given. A missing CA
    is taken from an imported intermediate in ca/<ca>/next/; it is only
    self-signed when no root is configured or --self-signed is given.

cluster-pki --ca-csr <etcd|k8s|front-proxy>
    Generate the next intermediate CA's key (ECDSA P-384) and CSR in
    ca/<ca>/next/. Sign ca.csr with the offline root (CA:TRUE, pathlen:0,
    keyCertSign), then --ca-import the cert.

cluster-pki --ca-import <etcd|k8s|front-proxy> CERT.pem
    Check the signed intermediate (matches the next key, critical CA:TRUE
    pathlen:0, keyCertSign, verifies against the root) and install it as
    ca/<ca>/next/ca.pem. Trust bundles change only at `--phase begin`.

cluster-pki --rotate-ca <etcd|k8s|front-proxy> [--phase PHASE] [--self-signed]
    PHASE  begin    put the next CA next to the current one; bundle = old+new.
                    Uses the imported intermediate in next/; without one it
                    self-signs a new CA, which needs --self-signed once a
                    root is configured
           reissue  new CA becomes the signer; re-issue that CA's leaves
                    (old leaves are copied to backup/<ts>/); bundle = new+old
           finish   drop the old CA (and adopted trust certs) from the bundle
           abort    (after begin only) retire the new CA; bundle = old
           rollback (after reissue only) old CA signs again, the latest
                    backup/ leaves are restored; bundle = old+new

cluster-pki --trust <etcd|k8s|front-proxy> FILE.pem [--out DIR]
    Add a PUBLIC CA cert (e.g. the legacy "ETCD CA 1") to that trust bundle
    so a cut-over from it never loses quorum. `finish` removes it again.

cluster-pki status [--out DIR]
    Show every leaf with issuer, expiry and whether it is up to date, then
    run check-anchors (exit 1 if it fails).

cluster-pki check-anchors [--out DIR]
    Fail if a trust bundle holds the root, a self-signed cert while that CA
    is an intermediate, or a cert that is not one of its own CA's
    generations (or adopted --trust certs); or if a leaf (or a cert in its
    chain) does not come from its own CA's generations.

cluster-pki deploy <node> [--out DIR] [--host SSH_HOST] [--staging DIR]
                   [--dry-run]
cluster-pki-deploy <node> ...      (same)
    Copy <node>'s files to SSH_HOST:STAGING/<node>/ (mode 0700/0600, no sudo)
    and print the exact sudo commands that install them into
    /var/lib/kubernetes/secrets. Never runs sudo itself.
EOF
}

die() { echo "cluster-pki: $*" >&2; exit 1; }
log() { echo "cluster-pki: $*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out) out=$2; shift 2 ;;
    --definition) def=$2; shift 2 ;;
    --root-ca) root_ca=$2; shift 2 ;;
    --self-signed) self_signed=1; shift ;;
    --ca-csr) mode=csr; csr_ca=$2; shift 2 ;;
    --ca-import) mode=import; import_ca=$2; import_file=$3; shift 3 ;;
    --renew) renew=1; shift ;;
    --node) only_node=$2; shift 2 ;;
    --rotate-ca) mode=rotate; rotate_ca=$2; shift 2 ;;
    --phase) phase=$2; shift 2 ;;
    --trust) mode=trust; trust_ca=$2; trust_file=$3; shift 3 ;;
    --host) deploy_host=$2; shift 2 ;;
    --staging) staging=$2; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    status) mode=status; shift ;;
    check-anchors) mode=check-anchors; shift ;;
    deploy) mode=deploy; deploy_node=${2:-}; shift; [ $# -gt 0 ] && shift ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[ -n "$def" ] && [ -r "$def" ] || die "definition JSON not readable: '$def'"
jq -e '.nodes | length > 0' "$def" >/dev/null || die "definition has no nodes"

# ---------------------------------------------------------------- definition
d() { jq -r "$1" "$def"; }
cluster_name=$(d '.name')
: "${out:=${XDG_DATA_HOME:-$HOME/.local/share}/cluster-pki/$cluster_name}"
if [ -n "$root_ca" ]; then
  [ -r "$root_ca" ] || die "root CA cert not readable: '$root_ca'"
fi
SECRETS_DIR=$(d ".secretsDir // \"/var/lib/kubernetes/secrets\"")
domain=$(d '.domain // empty')
nodes() { jq -r '.nodes | keys[]' "$def"; }
has_role() { jq -e --arg n "$1" --arg r "$2" \
  '.nodes[$n].roles | index($r) != null' "$def" >/dev/null; }
node_exists() { jq -e --arg n "$1" '.nodes | has($n)' "$def" >/dev/null; }

node_sans() {  # short name, FQDN, tailnet IP, LAN IP, loopback, extras
  jq -r --arg n "$1" --arg dom "$domain" '
    .nodes[$n] as $x
    | [ $n,
        (if $dom != "" then "\($n).\($dom)" else empty end),
        ($x.tailnetIP // empty), ($x.lanIP // empty),
        "127.0.0.1", "localhost" ] + ($x.extraSANs // [])
    | .[]' "$def"
}
apiserver_sans() {
  node_sans "$1"
  jq -r '
    [ (.vip // empty), (.kubernetesServiceIP // empty),
      "kubernetes", "kubernetes.default", "kubernetes.default.svc",
      "kubernetes.default.svc.\(.clusterDomain // "cluster.local")" ]
    + (.apiserverExtraSANs // []) | .[]' "$def"
}

# component|ca|profile|CN|O|sans|role
# CNs match what the NixOS kubernetes modules bind RBAC to (system:kube-apiserver
# for the kubelet client, flannel-client, system:node:<n> for the Node authorizer).
SPECS='etcd-peer|etcd|peer|@NODE@||node|etcd
etcd-server|etcd|peer|@NODE@||node|etcd
etcd-client-apiserver|etcd|client|kube-apiserver-etcd-client|||controlPlane
apiserver|k8s|server|kube-apiserver||apiserver|controlPlane
apiserver-kubelet-client|k8s|client|system:kube-apiserver|||controlPlane
front-proxy-client|front-proxy|client|front-proxy-client|||controlPlane
controller-manager|k8s|client|system:kube-controller-manager|||controlPlane
scheduler|k8s|client|system:kube-scheduler|||controlPlane
admin|k8s|client|cluster-admin|system:masters||controlPlane
addon-manager|k8s|client|system:kube-addon-manager|||controlPlane
kubelet|k8s|peer|system:node:@NODE@|system:nodes|node|worker
kube-proxy|k8s|client|system:kube-proxy|system:node-proxier||worker
flannel|k8s|client|flannel-client|||worker'

# Leaves of one node: "component|ca|profile|CN|O|sans" lines.
node_leaves() {
  local n=$1 comp ca prof cn o sans role
  while IFS='|' read -r comp ca prof cn o sans role; do
    has_role "$n" "$role" || continue
    echo "$comp|$ca|$prof|${cn//@NODE@/$n}|$o|$sans"
  done <<<"$SPECS"
}

bundle_name() {
  case "$1" in
    k8s) echo ca ;; etcd) echo etcd-ca ;; front-proxy) echo front-proxy-ca ;;
    *) die "unknown CA '$1' (etcd|k8s|front-proxy)" ;;
  esac
}
cas="k8s etcd front-proxy"

# Files a node needs, as "file|owner|mode".
node_files() {
  local n=$1 comp ca prof cn o sans owner
  local cp=0 etcd=0
  has_role "$n" controlPlane && cp=1
  has_role "$n" etcd && etcd=1
  echo "ca.pem|root|0644"
  if [ $cp = 1 ] || [ $etcd = 1 ]; then echo "etcd-ca.pem|root|0644"; fi
  if [ $cp = 1 ]; then
    echo "front-proxy-ca.pem|root|0644"
    echo "sa.pub|root|0644"
    echo "sa.key|kubernetes|0600"
  fi
  while IFS='|' read -r comp ca prof cn o sans; do
    case "$comp" in
      etcd-peer|etcd-server) owner=etcd ;;
      kubelet|kube-proxy|flannel|admin) owner=root ;;
      *) owner=kubernetes ;;
    esac
    echo "$comp-$n.pem|root|0644"
    echo "$comp-$n-key.pem|$owner|0600"
  done < <(node_leaves "$n")
}

# ---------------------------------------------------------------- helpers
cfssl_config() {
  local h=$1
  jq -n --arg h "${h}h" '{signing: {default: {expiry: $h}, profiles: {
    server: {expiry: $h, usages: ["signing","key encipherment","server auth"]},
    client: {expiry: $h, usages: ["signing","key encipherment","client auth"]},
    peer: {expiry: $h, usages:
      ["signing","key encipherment","server auth","client auth"]}}}}'
}

# Write $2 from stdin atomically.
atomic_write() {
  local dst=$1 tmp
  tmp=$(mktemp "$dst.XXXXXX")
  cat >"$tmp"
  chmod "${2:-0644}" "$tmp"
  mv -f "$tmp" "$dst"
}

ca_dir() { echo "$out/ca/$1"; }

# CA common name. The time of day keeps it unique when two CAs of one kind
# are made on the same day (e.g. begin, abort, begin): two CAs with the same
# subject in one bundle make issuer lookup by name ambiguous.
ca_cn() { echo "$cluster_name $1 CA $(date -u +%Y-%m-%dT%H%M%SZ)"; }

cert_fp() { openssl x509 -noout -fingerprint -sha256 -in "$1" | sed 's/.*=//'; }
cert_count() { grep -c -- '-----BEGIN CERTIFICATE-----' "$1" || true; }
is_self_signed() {  # subject == issuer (a root, or an old-style CA)
  [ "$(openssl x509 -noout -subject -nameopt RFC2253 -in "$1" | sed 's/^subject=//')" \
    = "$(openssl x509 -noout -issuer -nameopt RFC2253 -in "$1" | sed 's/^issuer=//')" ]
}
# Split a PEM file into $2/001.pem, $2/002.pem, ... (one cert each).
split_certs() {
  local in=$1 d=$2 i=0 line
  mkdir -p "$d"
  while IFS= read -r line; do
    if [ "$line" = "-----BEGIN CERTIFICATE-----" ]; then i=$((i + 1)); fi
    if [ $i -gt 0 ]; then printf '%s\n' "$line" >>"$d/$(printf %03d $i).pem"; fi
  done <"$in"
}
root_configured() { [ -n "$root_ca" ]; }
# The next CA exists but was only imported, not yet `begin`-ed.
next_pending() { [ -e "$(ca_dir "$1")/next/.pending" ]; }
next_imported() {
  local n; n=$(ca_dir "$1")/next
  [ -f "$n/ca-key.pem" ] && [ -f "$n/ca.pem" ]
}

init_ca() {  # $1 = ca, $2 = target dir (must not contain a key)
  local ca=$1 dir=$2 cn work
  [ -e "$dir/ca-key.pem" ] && die "refusing to overwrite CA key $dir/ca-key.pem"
  if root_configured && [ $self_signed = 0 ]; then
    die "$ca: a root CA is configured ($root_ca); refusing to self-sign a CA." \
      "Use --ca-csr $ca / --ca-import $ca, or pass --self-signed."
  fi
  mkdir -p "$dir"
  cn=$(ca_cn "$ca")
  work=$(mktemp -d)
  jq -n --arg cn "$cn" --arg o "$cluster_name" --arg e "${CA_HOURS}h" \
    --arg a "$KEY_ALGO" --argjson s "$KEY_SIZE" \
    '{CN: $cn, key: {algo: $a, size: $s}, names: [{O: $o, OU: "cluster-pki"}],
      ca: {expiry: $e}}' >"$work/csr.json"
  if ! cfssl gencert -initca "$work/csr.json" 2>"$work/log" \
      | (cd "$work" && cfssljson -bare ca); then
    cat "$work/log" >&2; rm -rf "$work"; die "CA generation failed"
  fi
  install -m 0600 "$work/ca-key.pem" "$dir/ca-key.pem"
  install -m 0644 "$work/ca.pem" "$dir/ca.pem"
  rm -rf "$work"
  log "created self-signed CA $ca: $cn ($dir)"
}

# Trust bundle = current + next + previous + trust/*. Never the root: Go
# (etcd, apiserver, kubelet) accepts an intermediate in the root pool as the
# anchor, and the root would also anchor the workload CA (docs/pki.md).
# A next CA that is only imported (.pending) is left out until `begin`.
write_bundle() {
  local ca=$1 dir f next=
  dir=$(ca_dir "$ca")
  next_pending "$ca" || next="$dir/next/ca.pem"
  {
    for f in "$dir/current/ca.pem" $next "$dir/previous/ca.pem" \
             "$dir"/trust/*.pem; do
      if [ -f "$f" ]; then cat "$f"; fi
    done
  } | atomic_write "$out/$(bundle_name "$ca").pem" 0644
  ln -sfn "ca/$ca/current/ca-key.pem" "$out/$(bundle_name "$ca")-key.pem"
}

ensure_cas() {
  local ca
  local dir
  for ca in $cas; do
    dir=$(ca_dir "$ca")
    if [ ! -f "$dir/current/ca-key.pem" ]; then
      if next_imported "$ca"; then
        # First CA of a new cluster, from --ca-csr/--ca-import.
        [ -e "$dir/current" ] && die "$ca: $dir/current exists without a key"
        rm -f "$dir/next/.pending"
        mv "$dir/next" "$dir/current"
        log "$ca: imported intermediate is the first $ca CA"
      else
        init_ca "$ca" "$dir/current"
      fi
    fi
    write_bundle "$ca"
  done
  if [ ! -f "$out/sa.key" ]; then
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
      -out "$out/sa.key" 2>/dev/null
    chmod 0600 "$out/sa.key"
    log "created service-account keypair"
  fi
  openssl pkey -in "$out/sa.key" -pubout 2>/dev/null \
    | atomic_write "$out/sa.pub" 0644
}

sans_of_cert() {
  openssl x509 -noout -ext subjectAltName -in "$1" 2>/dev/null \
    | tail -n +2 | tr ',' '\n' | sed -e 's/^ *//' -e 's/^DNS://' \
      -e 's/^IP Address://' | grep -v '^$' | sort -u || true
}
subject_of_cert() {
  openssl x509 -noout -subject -nameopt RFC2253 -in "$1" | sed 's/^subject=//'
}
expected_subject() {  # RFC2253 order is reversed: CN first
  if [ -n "$2" ]; then echo "CN=$1,O=$2"; else echo "CN=$1"; fi
}

# Server leaves (profile server/peer) of an intermediate CA carry the chain:
# leaf + intermediate, so clients that trust only the root can verify them.
wants_chain() {  # $1 profile, $2 CA cert
  case "$1" in server|peer) ! is_self_signed "$2" ;; *) return 1 ;; esac
}

# Why a leaf needs (re)issuing; empty = up to date.
leaf_reason() {
  local base=$1 ca=$2 cn=$3 o=$4 want_sans=$5 prof=$6 cadir have want_n=1
  cadir=$(ca_dir "$ca")/current
  [ -f "$base.pem" ] && [ -f "$base-key.pem" ] || { echo missing; return; }
  # -partial_chain: the CA may be an intermediate (anchor, like Go does).
  openssl verify -partial_chain -CAfile "$cadir/ca.pem" "$base.pem" >/dev/null 2>&1 \
    || { echo "not signed by current $ca CA"; return; }
  openssl x509 -noout -checkend $((RENEW_BEFORE_DAYS * 86400)) \
    -in "$base.pem" >/dev/null \
    || { echo "expires within ${RENEW_BEFORE_DAYS}d"; return; }
  [ "$(subject_of_cert "$base.pem")" = "$(expected_subject "$cn" "$o")" ] \
    || { echo "subject changed"; return; }
  have=$(sans_of_cert "$base.pem")
  [ "$have" = "$want_sans" ] || { echo "SANs changed"; return; }
  [ "$(openssl x509 -noout -pubkey -in "$base.pem")" = \
    "$(openssl pkey -pubout -in "$base-key.pem" 2>/dev/null)" ] \
    || { echo "key does not match cert"; return; }
  wants_chain "$prof" "$cadir/ca.pem" && want_n=2
  [ "$(cert_count "$base.pem")" = $want_n ] || { echo "chain changed"; return; }
  if [ $want_n = 2 ] && [ "$(cat "$cadir/ca.pem")" != \
      "$(tail -n "$(wc -l <"$cadir/ca.pem")" "$base.pem")" ]; then
    echo "chain changed"; return
  fi
  [ $renew = 1 ] && { echo "--renew"; return; }
  echo ""
}

backup_leaf() {
  local base=$1 bdir="$out/backup/$ts"
  [ -f "$base.pem" ] || return 0
  mkdir -p "$bdir"
  cp -p "$base.pem" "$base-key.pem" "$bdir/" 2>/dev/null || true
}

issue_leaf() {  # $1 base, $2 ca, $3 profile, $4 CN, $5 O, $6 sans (newline list)
  local base=$1 ca=$2 prof=$3 cn=$4 o=$5 sans=$6 cadir work hosts
  cadir=$(ca_dir "$ca")/current
  work=$(mktemp -d)
  cfssl_config "$LEAF_HOURS" >"$work/config.json"
  jq -n --arg cn "$cn" --arg o "$o" --arg a "$KEY_ALGO" --argjson s "$KEY_SIZE" \
    '{CN: $cn, key: {algo: $a, size: $s},
      names: (if $o == "" then [] else [{O: $o}] end)}' >"$work/csr.json"
  hosts=$(paste -sd, <<<"$sans")
  if ! cfssl gencert -ca "$cadir/ca.pem" -ca-key "$cadir/ca-key.pem" \
      -config "$work/config.json" -profile "$prof" -hostname "$hosts" \
      "$work/csr.json" 2>"$work/log" | (cd "$work" && cfssljson -bare leaf)
  then
    cat "$work/log" >&2; rm -rf "$work"; die "issuing $base failed"
  fi
  if wants_chain "$prof" "$cadir/ca.pem"; then
    cat "$cadir/ca.pem" >>"$work/leaf.pem"
  fi
  backup_leaf "$base"
  install -m 0600 "$work/leaf-key.pem" "$base-key.pem.new"
  install -m 0644 "$work/leaf.pem" "$base.pem.new"
  mv -f "$base-key.pem.new" "$base-key.pem"
  mv -f "$base.pem.new" "$base.pem"
  rm -rf "$work"
}

# Issue/refresh leaves. $1 = only this CA ("" = all), $2 = 1 to force.
generate_leaves() {
  local only_ca=$1 force=$2 n comp ca prof cn o sans want base why
  local issued=0 kept=0
  for n in $(nodes); do
    [ -n "$only_node" ] && [ "$n" != "$only_node" ] && continue
    while IFS='|' read -r comp ca prof cn o sans; do
      [ -n "$only_ca" ] && [ "$ca" != "$only_ca" ] && continue
      case "$sans" in
        node) want=$(node_sans "$n" | sort -u) ;;
        apiserver) want=$(apiserver_sans "$n" | sort -u) ;;
        *) want= ;;
      esac
      base="$out/$comp-$n"
      if [ "$force" = 1 ]; then why=forced; else
        why=$(leaf_reason "$base" "$ca" "$cn" "$o" "$want" "$prof"); fi
      if [ -n "$why" ]; then
        issue_leaf "$base" "$ca" "$prof" "$cn" "$o" "$want"
        log "issued $comp-$n ($why)"
        issued=$((issued + 1))
      else
        kept=$((kept + 1))
      fi
    done < <(node_leaves "$n")
  done
  log "leaves: $issued issued, $kept up to date"
}

ensure_out() {
  local d
  # Keys must never end up in a checkout (or a flake's store copy): refuse
  # an --out inside any directory that has .git or flake.nix.
  d=$(realpath -m "$out")
  while :; do
    if [ -e "$d/.git" ] || [ -e "$d/flake.nix" ]; then
      die "--out $out is inside $d (has .git or flake.nix); use a dir" \
        "outside any checkout, e.g. the default ~/.local/share/cluster-pki/<cluster>"
    fi
    [ "$d" = / ] && break
    d=$(dirname "$d")
  done
  mkdir -p "$out"
  chmod 0700 "$out"
  # Belt and braces: the dir ignores itself (.gitignore '*').
  [ -f "$out/.gitignore" ] || printf '*\n' >"$out/.gitignore"
  mkdir -p "$out/ca"
}

# ---------------------------------------------------------------- offline root
# --ca-csr: key + CSR for the next intermediate; the root signs it elsewhere.
ca_csr() {
  local ca=$1 dir cn
  bundle_name "$ca" >/dev/null
  dir=$(ca_dir "$ca")
  [ -e "$dir/next" ] && die "$ca: $dir/next exists (rotation begun, or CSR" \
    "already made). Discard it with --rotate-ca $ca --phase abort."
  [ -e "$dir/previous" ] && die "$ca: rotation not finished ($dir/previous exists)"
  mkdir -p "$dir/next"
  touch "$dir/next/.pending"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 \
    -out "$dir/next/ca-key.pem" 2>/dev/null
  chmod 0600 "$dir/next/ca-key.pem"
  cn=$(ca_cn "$ca")
  # The requested extensions are a hint; the root's signing profile decides.
  openssl req -new -sha384 -key "$dir/next/ca-key.pem" \
    -subj "/O=$cluster_name/CN=$cn" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$dir/next/ca.csr"
  chmod 0644 "$dir/next/ca.csr"
  log "$ca: CSR $dir/next/ca.csr (CN=$cn, O=$cluster_name, P-384)"
  log "public key sha256: $(openssl req -noout -pubkey -in "$dir/next/ca.csr" \
    | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1)"
  log "Sign it with the root (CA:TRUE pathlen:0, keyCertSign), then"
  log "  cluster-pki --ca-import $ca <cert.pem>"
}

# --ca-import: check the root-signed intermediate and install it as next.
ca_import() {
  local ca=$1 f=$2 dir bc
  bundle_name "$ca" >/dev/null
  dir=$(ca_dir "$ca")
  root_configured || die "no root CA configured (--root-ca FILE, or" \
    "$ROOT_CA_REPO_PATH in the repo at build time)"
  is_self_signed "$root_ca" || die "root $root_ca is not self-signed"
  { [ -f "$dir/next/ca-key.pem" ] && next_pending "$ca"; } \
    || die "$ca: no pending CSR in $dir/next; run --ca-csr $ca first"
  [ -e "$dir/next/ca.pem" ] && die "$ca: $dir/next/ca.pem already imported"
  [ -r "$f" ] || die "cannot read $f"
  grep -q 'PRIVATE KEY' "$f" && die "$f holds a private key"
  [ "$(cert_count "$f")" = 1 ] \
    || die "$f must hold exactly one certificate (the intermediate, no chain)"
  [ "$(openssl x509 -noout -pubkey -in "$f")" = \
    "$(openssl pkey -pubout -in "$dir/next/ca-key.pem")" ] \
    || die "$f does not match the key in $dir/next (wrong CSR or CA?)"
  bc=$(openssl x509 -noout -ext basicConstraints -in "$f" 2>/dev/null | tr -d ' \n')
  [ "$bc" = "X509v3BasicConstraints:criticalCA:TRUE,pathlen:0" ] \
    || die "$f: basicConstraints must be 'critical, CA:TRUE, pathlen:0' (got '$bc')"
  openssl x509 -noout -ext keyUsage -in "$f" 2>/dev/null \
    | grep -q 'Certificate Sign' || die "$f: keyUsage lacks keyCertSign"
  [ "$(cert_fp "$f")" != "$(cert_fp "$root_ca")" ] || die "$f is the root itself"
  openssl verify -x509_strict -CAfile "$root_ca" "$f" >/dev/null \
    || die "$f does not verify against the root $root_ca"
  if ! openssl x509 -noout -checkend \
      $(( LEAF_HOURS * 3600 + RENEW_BEFORE_DAYS * 86400 )) -in "$f" >/dev/null; then
    log "WARNING: $f expires before a ${LEAF_HOURS}h leaf would; cfssl does"
    log "not shorten leaves to the CA's lifetime."
  fi
  install -m 0644 "$f" "$dir/next/ca.pem"
  log "$ca: imported $(subject_of_cert "$f")"
  log "  issuer: $(openssl x509 -noout -issuer -nameopt RFC2253 -in "$f" | sed 's/^issuer=//')"
  if [ -f "$dir/current/ca-key.pem" ]; then
    log "Trust bundles are unchanged. Next: --rotate-ca $ca --phase begin"
  else
    log "No current $ca CA: the next 'cluster-pki' run makes it the first one."
  fi
}

# ---------------------------------------------------------------- anchors
# The anchor rule (docs/pki.md): a trust bundle holds only its own CA's
# generations (plus adopted --trust certs), never the root, never another
# branch, and no self-signed cert once that CA is an intermediate.
# Prints one line per problem; returns non-zero if there is any.
check_anchors() {
  local fails=0 ca other dir f g fp tmp root_fp='' inter b n comp prof cn o sans
  tmp=$(mktemp -d)
  if root_configured; then root_fp=$(cert_fp "$root_ca"); fi
  bad() { echo "check-anchors: FAIL: $*"; fails=$((fails + 1)); }
  for ca in $cas; do  # every CA's generations (current/next/previous)
    dir=$(ca_dir "$ca")
    : >"$tmp/$ca.fps"; : >"$tmp/$ca.gens.pem"; : >"$tmp/$ca.trust"
    inter=0
    for f in "$dir"/current/ca.pem "$dir"/next/ca.pem "$dir"/previous/ca.pem; do
      [ -f "$f" ] || continue
      cert_fp "$f" >>"$tmp/$ca.fps"; cat "$f" >>"$tmp/$ca.gens.pem"
      is_self_signed "$f" || inter=1
    done
    echo "$inter" >"$tmp/$ca.inter"
    for f in "$dir"/trust/*.pem; do
      if [ -f "$f" ]; then cert_fp "$f" >>"$tmp/$ca.trust"; fi
    done
  done
  for ca in $cas; do
    b="$out/$(bundle_name "$ca").pem"
    if [ ! -s "$b" ]; then bad "$b is missing or empty"; continue; fi
    inter=$(cat "$tmp/$ca.inter")
    : >"$tmp/bundle-$ca.fps"
    split_certs "$b" "$tmp/bundle-$ca"
    for f in "$tmp/bundle-$ca"/*.pem; do
      [ -f "$f" ] || continue
      fp=$(cert_fp "$f")
      cn=$(subject_of_cert "$f")
      echo "$fp" >>"$tmp/bundle-$ca.fps"
      if [ "$fp" = "$root_fp" ]; then bad "$b contains the root CA ($cn)"; fi
      if [ "$inter" = 1 ] && is_self_signed "$f"; then
        bad "$b contains self-signed $cn, but the $ca CA is an intermediate"
      fi
      for other in $cas; do
        [ "$other" = "$ca" ] && continue
        if grep -qxF "$fp" "$tmp/$other.fps"; then
          bad "$b contains the $other CA $cn"
        fi
      done
      grep -qxF "$fp" "$tmp/$ca.fps" || grep -qxF "$fp" "$tmp/$ca.trust" \
        || bad "$b contains $cn, which is not a $ca CA generation or --trust cert"
    done
    g=$(ca_dir "$ca")/current/ca.pem
    if [ -f "$g" ] && ! grep -qxF "$(cert_fp "$g")" "$tmp/bundle-$ca.fps"; then
      bad "$b lacks the current $ca CA"
    fi
  done
  # Each leaf must be issued by one of its own CA's generations, and any
  # chain cert in its file must be one of them too (never root/other CA).
  for n in $(nodes); do
    while IFS='|' read -r comp ca prof cn o sans; do
      f="$out/$comp-$n.pem"
      [ -f "$f" ] || continue
      rm -rf "$tmp/leaf"; split_certs "$f" "$tmp/leaf"
      if [ ! -s "$tmp/$ca.gens.pem" ] || ! openssl verify -partial_chain \
          -no_check_time -CAfile "$tmp/$ca.gens.pem" "$tmp/leaf/001.pem" \
          >/dev/null 2>&1; then
        bad "$comp-$n.pem: issuer is not one of the $ca CA's generations"
      fi
      for g in "$tmp/leaf"/*.pem; do
        [ "$g" = "$tmp/leaf/001.pem" ] && continue
        grep -qxF "$(cert_fp "$g")" "$tmp/$ca.fps" \
          || bad "$comp-$n.pem: chain holds $(subject_of_cert "$g"), not a $ca CA"
      done
    done < <(node_leaves "$n")
  done
  rm -rf "$tmp"
  if [ $fails = 0 ]; then
    echo "check-anchors: ok (each bundle holds only its own CA's generations)"
  fi
  [ $fails = 0 ]
}

# ---------------------------------------------------------------- rotation
rotate() {
  local ca=$1 dir
  bundle_name "$ca" >/dev/null
  dir=$(ca_dir "$ca")
  [ -f "$dir/current/ca-key.pem" ] || die "no current $ca CA; run cluster-pki first"
  case "$phase" in
    begin)
      [ -e "$dir/previous" ] && die "$ca rotation not finished ($dir/previous exists)"
      if next_pending "$ca"; then
        next_imported "$ca" || die "$ca: $dir/next has a CSR but no cert;" \
          "sign it with the root and run --ca-import $ca <cert.pem>"
        rm -f "$dir/next/.pending"
        log "$ca: using the imported intermediate $(subject_of_cert "$dir/next/ca.pem")"
      elif [ -e "$dir/next" ]; then
        die "$ca rotation already begun ($dir/next exists)"
      else
        init_ca "$ca" "$dir/next"   # self-signed; refuses if a root exists
      fi
      write_bundle "$ca"
      log "$ca: bundle now old+new. Deploy $(bundle_name "$ca").pem to every"
      log "node one at a time (docs/pki.md), then --phase reissue."
      ;;
    reissue)
      { [ -f "$dir/next/ca-key.pem" ] && [ -f "$dir/next/ca.pem" ] \
        && ! next_pending "$ca"; } || die "$ca: no begun next CA; run --phase begin"
      [ -e "$dir/previous" ] && die "$ca: $dir/previous exists; finish first"
      mv "$dir/current" "$dir/previous"
      mv "$dir/next" "$dir/current"
      write_bundle "$ca"
      generate_leaves "$ca" 1
      if [ -d "$out/backup/$ts" ]; then
        echo "$ts" >"$dir/previous/backup-ts"
      fi
      log "$ca: new CA signs; leaves re-issued (old ones in backup/$ts)."
      log "Deploy leaves one node at a time, then --phase finish."
      ;;
    finish)
      [ -e "$dir/next" ] && die "$ca: next CA not promoted yet; run reissue"
      mkdir -p "$dir/retired/$ts"
      [ -d "$dir/previous" ] && mv "$dir/previous" "$dir/retired/$ts/ca"
      local t
      for t in "$dir"/trust/*.pem; do
        [ -f "$t" ] || continue
        mkdir -p "$dir/retired/$ts/trust"
        mv "$t" "$dir/retired/$ts/trust/"
      done
      rmdir "$dir/retired/$ts" 2>/dev/null || true
      write_bundle "$ca"
      log "$ca: bundle now holds only the current CA. Deploy it everywhere."
      ;;
    abort)
      [ -d "$dir/next" ] || die "$ca: nothing to abort (no next CA)"
      mkdir -p "$dir/retired/$ts"
      mv "$dir/next" "$dir/retired/$ts/aborted-next"
      write_bundle "$ca"
      log "$ca: rotation aborted; bundle = old CA (+trust)."
      ;;
    rollback)
      [ -d "$dir/previous" ] || die "$ca: nothing to roll back (no previous CA)"
      [ -e "$dir/next" ] && die "$ca: $dir/next exists; resolve manually"
      local bts
      bts=$(cat "$dir/previous/backup-ts" 2>/dev/null || true)
      rm -f "$dir/previous/backup-ts"
      mv "$dir/current" "$dir/next"
      mv "$dir/previous" "$dir/current"
      if [ -n "$bts" ] && [ -d "$out/backup/$bts" ]; then
        cp -p "$out/backup/$bts"/*.pem "$out/"
        log "$ca: restored leaves from backup/$bts"
      else
        generate_leaves "$ca" 1
      fi
      write_bundle "$ca"
      log "$ca: old CA signs again; bundle = old+new (state as after begin)."
      ;;
    *) die "unknown phase '$phase'" ;;
  esac
}

# ---------------------------------------------------------------- status
status() {
  local n comp ca prof cn o sans want base why end
  printf '%-40s %-12s %-26s %s\n' LEAF CA NOT_AFTER STATE
  for n in $(nodes); do
    while IFS='|' read -r comp ca prof cn o sans; do
      case "$sans" in
        node) want=$(node_sans "$n" | sort -u) ;;
        apiserver) want=$(apiserver_sans "$n" | sort -u) ;;
        *) want= ;;
      esac
      base="$out/$comp-$n"
      why=$(leaf_reason "$base" "$ca" "$cn" "$o" "$want" "$prof")
      end=-
      [ -f "$base.pem" ] && end=$(openssl x509 -noout -enddate -in "$base.pem" \
        | sed 's/notAfter=//')
      printf '%-40s %-12s %-26s %s\n' "$comp-$n" "$ca" "$end" "${why:-ok}"
    done < <(node_leaves "$n")
  done
  for ca in $cas; do
    echo "== $ca trust bundle ($(bundle_name "$ca").pem):"
    openssl crl2pkcs7 -nocrl -certfile "$out/$(bundle_name "$ca").pem" \
      | openssl pkcs7 -print_certs -noout | grep '^subject' || true
    if next_pending "$ca"; then
      if next_imported "$ca"; then
        echo "   pending next CA in ca/$ca/next: imported, run --phase begin"
      else
        echo "   pending next CA in ca/$ca/next: CSR only, awaiting --ca-import"
      fi
    fi
  done
  check_anchors
}

# ---------------------------------------------------------------- deploy
deploy() {
  local n=$1 host stage list f owner mode
  [ -n "$n" ] || die "usage: cluster-pki-deploy <node>"
  node_exists "$n" || die "unknown node '$n' (have: $(nodes | paste -sd' '))"
  host=${deploy_host:-$(jq -r --arg n "$n" '.nodes[$n].sshHost // $n' "$def")}
  stage="$staging/$n"
  list=$(node_files "$n")
  # Check everything locally before anything leaves this machine.
  check_anchors >&2 || die "trust anchors are wrong; not deploying"
  while IFS='|' read -r f owner mode; do
    [ -f "$out/$f" ] || die "missing $out/$f; run cluster-pki first"
  done <<<"$list"
  while read -r f; do
    case "$f" in
      etcd-*) ca="etcd-ca" ;;
      front-proxy-*) ca="front-proxy-ca" ;;
      *) ca="ca" ;;
    esac
    openssl verify -partial_chain -CAfile "$out/$ca.pem" "$out/$f" >/dev/null \
      || die "$f does not verify against $ca.pem"
  done < <(grep -o "^[^|]*-$n\.pem" <<<"$list")
  if [ $dry_run = 0 ]; then
    # tar over ssh: works with any login shell (fish on m2mini), needs no rsync.
    # shellcheck disable=SC2046,SC2029
    tar -C "$out" -cf - --mode=go-rwx $(cut -d'|' -f1 <<<"$list") \
      | ssh "$host" "sh -c 'umask 077; rm -rf $stage && mkdir -p $stage \
          && tar -xf - -C $stage --no-same-owner && chmod 700 $stage'"
    log "copied $(wc -l <<<"$list") files to $host:~/$stage"
  else
    log "dry run: would copy to $host:~/$stage:"
    cut -d'|' -f1 <<<"$list" | sed 's/^/  /' >&2
  fi
  local units=""
  if has_role "$n" controlPlane; then
    units="kube-apiserver kube-controller-manager kube-scheduler"
  fi
  # flannel is a DaemonSet (k8s/), not a unit.
  if has_role "$n" worker; then units="$units kubelet kube-proxy"; fi
  cat <<EOF

# ---- on $n: 'ssh -t $host bash' (bash, not fish), then paste ----
# The etcd and kubernetes users must exist (services.etcd and any
# services.kubernetes.* component create them). On a node's first switch to
# the new layout: switch, run these, then restart the units.
S=~/$stage; D=$SECRETS_DIR
sudo mkdir -p /var/lib/kubernetes
sudo install -d -m 0755 -o root -g root "\$D"
EOF
  while IFS='|' read -r f owner mode; do
    echo "sudo install -m $mode -o $owner -g $owner \"\$S/$f\" \"\$D/$f\""
  done <<<"$list"
  # shellcheck disable=SC2016 # printed literally for the node's shell
  echo 'rm -rf "$S"'
  # shellcheck disable=SC2016
  echo 'sudo ls -l "$D"'
  if has_role "$n" etcd; then
    cat <<EOF
# etcd: ONE member at a time, only while 'endpoint health --cluster' is green:
sudo systemctl restart etcd
sudo etcdctl --endpoints=https://$n:2379 --cacert="\$D/etcd-ca.pem" \\
  --cert="\$D/etcd-server-$n.pem" --key="\$D/etcd-server-$n-key.pem" \\
  endpoint health --cluster
EOF
  fi
  if [ -n "$units" ]; then
    echo "sudo systemctl restart ${units# }"
  fi
}

# ---------------------------------------------------------------- main
case "$mode" in
  generate)
    ensure_out; ensure_cas
    if [ -n "$only_node" ]; then
      node_exists "$only_node" || die "unknown node $only_node"
    fi
    generate_leaves "" 0
    ;;
  rotate) ensure_out; rotate "$rotate_ca" ;;
  trust)
    ensure_out; bundle_name "$trust_ca" >/dev/null
    [ -r "$trust_file" ] || die "cannot read $trust_file"
    openssl x509 -noout -in "$trust_file" 2>/dev/null \
      || die "$trust_file is not a PEM certificate"
    grep -q 'PRIVATE KEY' "$trust_file" && die "$trust_file holds a private key"
    if root_configured && [ "$(cert_fp "$trust_file")" = "$(cert_fp "$root_ca")" ]; then
      die "$trust_file is the root CA; bundles must never hold it"
    fi
    mkdir -p "$(ca_dir "$trust_ca")/trust"
    fp=$(openssl x509 -noout -fingerprint -sha256 -in "$trust_file" \
      | sed 's/.*=//; s/://g' | cut -c1-16)
    install -m 0644 "$trust_file" "$(ca_dir "$trust_ca")/trust/$fp.pem"
    write_bundle "$trust_ca"
    log "$trust_ca bundle now also trusts $(subject_of_cert "$trust_file")"
    ;;
  csr) ensure_out; ca_csr "$csr_ca" ;;
  import) ensure_out; ca_import "$import_ca" "$import_file" ;;
  status) [ -d "$out/ca" ] || die "no PKI in $out"; status ;;
  check-anchors) [ -d "$out/ca" ] || die "no PKI in $out"; check_anchors ;;
  deploy) [ -d "$out/ca" ] || die "no PKI in $out"; deploy "$deploy_node" ;;
esac
