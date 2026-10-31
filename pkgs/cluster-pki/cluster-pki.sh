# cluster-pki: generate and rotate the cluster PKI from cluster/definition.nix.
#
# Prepended by default.nix:
#   CLUSTER_PKI_DEFINITION  JSON projection of cluster/definition.nix (store path)
#
# Layout of the output dir (default ./pki-out, operator machine only):
#   ca/<k8s|etcd|front-proxy>/current/{ca.pem,ca-key.pem}   signing CA
#   ca/<ca>/next/        new CA during a rotation (after `begin`)
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

out=./pki-out
def=${CLUSTER_PKI_DEFINITION:-}
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
cluster-pki [--out DIR] [--definition FILE.json] [--renew] [--node NAME]
    Create missing CAs, the SA keypair and every node's leaves. Idempotent:
    CA keys are never overwritten; a leaf is (re)issued only when missing,
    not signed by the current CA, its SANs/subject differ from the
    definition, it expires within 30 days, or --renew is given.

cluster-pki --rotate-ca <etcd|k8s|front-proxy> [--phase PHASE] [--out DIR]
    PHASE  begin    create a new CA next to the current one; bundle = old+new
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
    Show every leaf with issuer, expiry and whether it is up to date.

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
    --renew) renew=1; shift ;;
    --node) only_node=$2; shift 2 ;;
    --rotate-ca) mode=rotate; rotate_ca=$2; shift 2 ;;
    --phase) phase=$2; shift 2 ;;
    --trust) mode=trust; trust_ca=$2; trust_file=$3; shift 3 ;;
    --host) deploy_host=$2; shift 2 ;;
    --staging) staging=$2; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    status) mode=status; shift ;;
    deploy) mode=deploy; deploy_node=${2:-}; shift; [ $# -gt 0 ] && shift ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[ -n "$def" ] && [ -r "$def" ] || die "definition JSON not readable: '$def'"
jq -e '.nodes | length > 0' "$def" >/dev/null || die "definition has no nodes"

# ---------------------------------------------------------------- definition
d() { jq -r "$1" "$def"; }
cluster_name=$(d '.name')
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

init_ca() {  # $1 = ca, $2 = target dir (must not contain a key)
  local ca=$1 dir=$2 cn work
  [ -e "$dir/ca-key.pem" ] && die "refusing to overwrite CA key $dir/ca-key.pem"
  mkdir -p "$dir"
  cn="$cluster_name $ca CA $(date -u +%Y-%m-%d)"
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
  log "created CA $ca: $cn ($dir)"
}

write_bundle() {  # trust bundle = current + next + previous + trust/*
  local ca=$1 dir f
  dir=$(ca_dir "$ca")
  {
    for f in "$dir/current/ca.pem" "$dir/next/ca.pem" "$dir/previous/ca.pem" \
             "$dir"/trust/*.pem; do
      if [ -f "$f" ]; then cat "$f"; fi
    done
  } | atomic_write "$out/$(bundle_name "$ca").pem" 0644
  ln -sfn "ca/$ca/current/ca-key.pem" "$out/$(bundle_name "$ca")-key.pem"
}

ensure_cas() {
  local ca
  for ca in $cas; do
    [ -f "$(ca_dir "$ca")/current/ca-key.pem" ] \
      || init_ca "$ca" "$(ca_dir "$ca")/current"
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

# Why a leaf needs (re)issuing; empty = up to date.
leaf_reason() {
  local base=$1 ca=$2 cn=$3 o=$4 want_sans=$5 cadir have
  cadir=$(ca_dir "$ca")/current
  [ -f "$base.pem" ] && [ -f "$base-key.pem" ] || { echo missing; return; }
  openssl verify -CAfile "$cadir/ca.pem" "$base.pem" >/dev/null 2>&1 \
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
        why=$(leaf_reason "$base" "$ca" "$cn" "$o" "$want"); fi
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
  mkdir -p "$out"
  chmod 0700 "$out"
  local top
  # Keys must never be committed. The dir ignores itself (.gitignore '*');
  # inside a git work tree, double-check that git really ignores a key path.
  [ -f "$out/.gitignore" ] || printf '*\n' >"$out/.gitignore"
  if top=$(git -C "$out" rev-parse --show-toplevel 2>/dev/null) \
      && ! git -C "$top" check-ignore -q "$(realpath "$out")/ca-key.pem"; then
    die "$out is inside git repo $top but git does not ignore it; refusing"
  fi
  mkdir -p "$out/ca"
}

# ---------------------------------------------------------------- rotation
rotate() {
  local ca=$1 dir
  bundle_name "$ca" >/dev/null
  dir=$(ca_dir "$ca")
  [ -f "$dir/current/ca-key.pem" ] || die "no current $ca CA; run cluster-pki first"
  case "$phase" in
    begin)
      [ -e "$dir/next" ] && die "$ca rotation already begun ($dir/next exists)"
      [ -e "$dir/previous" ] && die "$ca rotation not finished ($dir/previous exists)"
      init_ca "$ca" "$dir/next"
      write_bundle "$ca"
      log "$ca: bundle now old+new. Deploy $(bundle_name "$ca").pem to every"
      log "node one at a time (docs/pki.md), then --phase reissue."
      ;;
    reissue)
      [ -f "$dir/next/ca-key.pem" ] || die "$ca: no next CA; run --phase begin"
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
      why=$(leaf_reason "$base" "$ca" "$cn" "$o" "$want")
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
  done
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
  while IFS='|' read -r f owner mode; do
    [ -f "$out/$f" ] || die "missing $out/$f; run cluster-pki first"
  done <<<"$list"
  while read -r f; do
    case "$f" in
      etcd-*) ca="etcd-ca" ;;
      front-proxy-*) ca="front-proxy-ca" ;;
      *) ca="ca" ;;
    esac
    openssl verify -CAfile "$out/$ca.pem" "$out/$f" >/dev/null \
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
    mkdir -p "$(ca_dir "$trust_ca")/trust"
    fp=$(openssl x509 -noout -fingerprint -sha256 -in "$trust_file" \
      | sed 's/.*=//; s/://g' | cut -c1-16)
    install -m 0644 "$trust_file" "$(ca_dir "$trust_ca")/trust/$fp.pem"
    write_bundle "$trust_ca"
    log "$trust_ca bundle now also trusts $(subject_of_cert "$trust_file")"
    ;;
  status) [ -d "$out/ca" ] || die "no PKI in $out"; status ;;
  deploy) [ -d "$out/ca" ] || die "no PKI in $out"; deploy "$deploy_node" ;;
esac
