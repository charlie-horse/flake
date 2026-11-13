#!/usr/bin/env bash
# neurosis root CA ceremony (docs/pki-migration-plan.md, node F). DRAFT.
#
# Host-agnostic: runs on whatever machine the user plugs the admin YubiKey
# 19830800 into (PIN, PUK and PIN-protected management key already set; sops
# age key in slot 82 -- never touched here), from a checkout of this repo
# (only .sops.yaml is read). User physically present. Tools:
#   nix shell <flake>#ca-ceremony-tools
#   (ykman, step, step-kms-plugin, ca-openssl, ca-pcscd, sops,
#   age-plugin-yubikey, yq, softhsm2-util; this script is `ca-ceremony`)
#   CSR_DIR=~/csrs ca-ceremony        # k8s.csr etcd.csr front-proxy.csr from r440
# Root is needed only if no pcscd is reachable and ca-pcscd must be started.
#
# Rehearsal (node E, software key in SoftHSM through step-kms-plugin, no card):
#   MODE=rehearsal CSR_DIR=... ca-ceremony
#
# PIN+touch count: 1 (root self-sign) + 4 (intermediates). ykman also asks
# the PIN to unlock the protected management key for `generate` and `import`.
# The PIN is never on a command line or in history: it is read with `read -s`
# into a 0600 file on tmpfs (step's KMS URI `pin-source=`), removed on exit.
# Without pin-source the step yubikey KMS silently uses the DEFAULT PIN
# 123456, which burns one of the 3 PIN tries.
set -euo pipefail
umask 077

MODE=${MODE:-yubikey}                 # yubikey | rehearsal
SERIAL=19830800
SLOT=9c
REPO=${REPO:-$(git rev-parse --show-toplevel 2>/dev/null || true)}   # read only: .sops.yaml
CSR_DIR=${CSR_DIR:?set CSR_DIR to the dir holding k8s.csr etcd.csr front-proxy.csr}
OUT=${OUT:-$HOME/ceremony-$(date +%Y%m%d)}   # public certs + the sops-encrypted Secret
SECRET_PATH=k8s/secrets/cert-manager/cluster-ca.sops.yaml
ROOT_CN="neurosis Root CA 2026"
ROOT_LIFE=175320h                     # 20 y (7305 d)
BOOT_LIFE=43824h                      # 5 y (1826 d): k8s, etcd, front-proxy
WORKLOAD_LIFE=17520h                  # 2 y (730 d): workload

die() { echo "ERROR: $*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }
confirm() { [[ $MODE == rehearsal ]] && return 0; read -r -p "$1 [type yes] " a; [[ $a == yes ]] || die "aborted"; }

OSSL=$(command -v ca-openssl || command -v openssl) || die "missing ca-openssl"
openssl() { "$OSSL" "$@"; }
for c in step step-kms-plugin sops yq age-plugin-yubikey; do
  command -v "$c" >/dev/null || die "missing $c (see the nix shell line at the top)"
done
[[ -n $REPO && -f $REPO/.sops.yaml ]] || die "run from a checkout of the flake repo (or set REPO): no .sops.yaml"
for ca in k8s etcd front-proxy; do [[ -f $CSR_DIR/$ca.csr ]] || die "missing $CSR_DIR/$ca.csr"; done
[[ -e $OUT ]] && die "$OUT exists; refusing to overwrite"

TMPROOT=${XDG_RUNTIME_DIR:-/dev/shm}
[[ $(stat -f -c %T "$TMPROOT" 2>/dev/null) == tmpfs ]] || TMPROOT=/dev/shm
[[ $(stat -f -c %T "$TMPROOT" 2>/dev/null) == tmpfs ]] || die "no tmpfs for the PIN file and workload key"
WORK=$(mktemp -d "$TMPROOT/ceremony.XXXXXX")   # tmpfs: PIN file, workload key
cleanup() { find "$WORK" -type f -exec shred -u {} + 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$OUT"

# --- KMS selection ---------------------------------------------------------
if [[ $MODE == yubikey ]]; then
  command -v ykman >/dev/null || die "missing ykman"
  # Use the machine's pcscd if it can see the card; start ca-pcscd only if
  # none is reachable (needs root). ca-pcscd runs pcscd --foreground
  # --auto-exit (~60 s idle), so this is re-checked before every card step
  # and ours is restarted as needed. ca-pcscd refuses to start while any
  # pcscd runs, so first wait for our previous one to finish exiting.
  card_visible() { ykman list --serials 2>/dev/null | grep -qx "$SERIAL"; }
  OWN_PCSCD=0
  PCSCD_PID=
  ensure_pcscd() {
    card_visible && return 0
    if (( ! OWN_PCSCD )) && pgrep -x pcscd >/dev/null; then
      die "a pcscd is running but YubiKey $SERIAL is not visible (plugged in? polkit denies this user? try as root)"
    fi
    command -v ca-pcscd >/dev/null || die "no pcscd reachable and ca-pcscd missing"
    [[ $(id -u) == 0 ]] || die "no pcscd reachable: rerun as root so ca-pcscd can be started"
    if [[ -n $PCSCD_PID ]]; then wait "$PCSCD_PID" 2>/dev/null || true; fi
    ca-pcscd & PCSCD_PID=$! OWN_PCSCD=1
    for _ in 1 2 3 4 5 6 7 8 9 10; do card_visible && return 0; sleep 1; done
    die "YubiKey $SERIAL not visible after starting ca-pcscd"
  }
  yk() { ensure_pcscd; ykman --device "$SERIAL" "$@"; }
  KMS="yubikey:serial=$SERIAL?pin-source=$WORK/pin"
  KEY="yubikey:slot-id=$SLOT"
else
  SOFTHSM_LIB=$(dirname "$(readlink -f "$(command -v softhsm2-util)")")/../lib/softhsm/libsofthsm2.so
  export SOFTHSM2_CONF=$WORK/softhsm2.conf
  mkdir "$WORK/tokens"
  printf 'directories.tokendir = %s\nobjectstore.backend = file\nlog.level = ERROR\n' "$WORK/tokens" > "$SOFTHSM2_CONF"
  softhsm2-util --init-token --free --label rehearsal --so-pin 12345678 --pin rehearsal >/dev/null
  ensure_pcscd() { :; }
  KMS="pkcs11:module-path=$SOFTHSM_LIB;token=rehearsal?pin-source=$WORK/pin"
  KEY="pkcs11:id=9c;object=root"
fi

# --- 1. Preflight: right card, 9c empty, record slot 82 --------------------
if [[ $MODE == yubikey ]]; then
  say "YubiKey"
  yk info | tee "$OUT/ykman-info.txt"
  grep -Eq 'Firmware version: +5\.([3-9]|[1-9][0-9])' "$OUT/ykman-info.txt" || die "need firmware >= 5.3 (P-384, key metadata, attestation)"
  yk piv info | tee "$OUT/ykman-piv-info-before.txt"
  if yk piv keys info "$SLOT" >/dev/null 2>&1; then die "slot $SLOT already holds a key; refusing (never reset this card)"; fi
  if yk piv certificates export "$SLOT" - >/dev/null 2>&1; then die "slot $SLOT already holds a certificate; refusing"; fi
  SLOT82_BEFORE=$(yk piv keys export 82 - | sha256sum)
fi

say "PIV PIN (not echoed; used for the 5 signatures)"
if [[ $MODE == yubikey ]]; then
  read -r -s -p "PIV PIN: " PIN; echo
  printf '%s' "$PIN" > "$WORK/pin"; unset PIN
else
  printf 'rehearsal' > "$WORK/pin"
fi

# --- 2. Generate the root key in 9c + attestation --------------------------
if [[ $MODE == yubikey ]]; then
  say "Generating P-384 key in $SLOT (PIN for the management key)"
  yk piv keys generate --algorithm ECCP384 --pin-policy ALWAYS --touch-policy ALWAYS "$SLOT" "$WORK/root.pub"
  yk piv keys attest "$SLOT" "$OUT/attest-9c.pem"
  yk piv certificates export f9 "$OUT/attest-f9.pem"
  openssl verify -partial_chain -CAfile "$OUT/attest-f9.pem" "$OUT/attest-9c.pem" || die "attestation does not chain to f9"
  cmp <(openssl x509 -in "$OUT/attest-9c.pem" -noout -pubkey) "$WORK/root.pub" || die "attested key != generated key"
else
  step-kms-plugin create --kms "$KMS" --kty EC --crv P384 "$KEY" >/dev/null
  step-kms-plugin key --kms "$KMS" "$KEY" > "$WORK/root.pub"
fi
cp "$WORK/root.pub" "$OUT/root.pub"

# --- 3. Self-sign the root (1x PIN+touch) ----------------------------------
# step's root-ca profile gives the right KU/BC but no O= and no AKI; the
# template adds both. SKI = SHA-1 of the subjectPublicKey (RFC 5280 method 1,
# same value Go/step compute), set as AKI too.
spki=$(openssl pkey -pubin -in "$WORK/root.pub" -outform DER | base64 -w0)
[[ $(base64 -d <<<"$spki" | wc -c) == 120 ]] || die "root.pub is not an uncompressed P-384 key"
SKI=$(base64 -d <<<"$spki" | tail -c 97 | openssl dgst -sha1 -binary | base64 -w0)
cat > "$WORK/root.tpl" <<EOF
{
  "subject": {"commonName": "$ROOT_CN", "organization": "neurosis"},
  "issuer":  {"commonName": "$ROOT_CN", "organization": "neurosis"},
  "subjectKeyId": "$SKI",
  "authorityKeyId": "$SKI",
  "keyUsage": ["certSign", "crlSign"],
  "basicConstraints": {"isCA": true, "maxPathLen": 1}
}
EOF
cat > "$WORK/intermediate.tpl" <<'EOF'
{
  "subject": {{ toJson .Subject }},
  "keyUsage": ["certSign", "crlSign"],
  "basicConstraints": {"isCA": true, "maxPathLen": 0}
}
EOF
say "Self-signing the root: touch the key when it blinks"
ensure_pcscd
step certificate create --template "$WORK/root.tpl" --not-after "$ROOT_LIFE" \
  --skip-csr-signature --kms "$KMS" --key "$KEY" "$ROOT_CN" "$OUT/root.pem"
cmp <(openssl x509 -in "$OUT/root.pem" -noout -pubkey) "$WORK/root.pub" || die "root cert key mismatch"
openssl verify -x509_strict -CAfile "$OUT/root.pem" "$OUT/root.pem"

if [[ $MODE == yubikey ]]; then
  say "Importing root.pem into $SLOT (PIN for the management key)"
  yk piv certificates import --no-update-chuid "$SLOT" "$OUT/root.pem"
fi

# --- 4. Intermediates (1x PIN+touch each) ----------------------------------
say "Workload intermediate key + CSR (tmpfs only)"
openssl ecparam -name secp384r1 -genkey -noout -out "$WORK/workload.key"
openssl req -new -key "$WORK/workload.key" -subj "/O=neurosis/CN=neurosis workload CA" -out "$OUT/workload.csr"
cp "$CSR_DIR"/{k8s,etcd,front-proxy}.csr "$OUT/"

for ca in workload k8s etcd front-proxy; do
  csr=$OUT/$ca.csr
  openssl req -in "$csr" -noout -verify 2>&1 | grep -q 'verify OK\|self-signature ok' || die "$ca.csr: bad signature"
  echo "$ca: $(openssl req -in "$csr" -noout -subject)"
done
confirm "Sign these four CSRs?"

for ca in workload k8s etcd front-proxy; do
  life=$BOOT_LIFE; [[ $ca == workload ]] && life=$WORKLOAD_LIFE
  say "Signing $ca intermediate: touch the key when it blinks"
  ensure_pcscd
  step certificate sign --template "$WORK/intermediate.tpl" --not-after "$life" \
    --kms "$KMS" "$OUT/$ca.csr" "$OUT/root.pem" "$KEY" > "$OUT/$ca.pem"
  openssl verify -x509_strict -CAfile "$OUT/root.pem" "$OUT/$ca.pem"
  openssl x509 -in "$OUT/$ca.pem" -noout -ext basicConstraints | grep -q 'CA:TRUE, pathlen:0' || die "$ca: pathlen"
  openssl x509 -in "$OUT/$ca.pem" -noout -ext keyUsage | grep -q 'critical' || die "$ca: keyUsage not critical"
done
cmp <(openssl x509 -in "$OUT/workload.pem" -noout -pubkey) <(openssl pkey -in "$WORK/workload.key" -pubout) || die "workload key mismatch"

# --- 5. Workload Secret, sops-encrypted straight from tmpfs ----------------
# k8s/README.md "Adding one": keys sorted, data = base64 of exact bytes.
# type kubernetes.io/tls to match the Secret cert-manager made (type is immutable).
say "Encrypting cert-manager/cluster-ca -> $OUT/cluster-ca.sops.yaml (for $SECRET_PATH)"
b64() { base64 -w0 "$@"; }
{
  printf 'apiVersion: v1\ndata:\n'
  printf '  ca.crt: %s\n'  "$(b64 "$OUT/root.pem")"
  printf '  tls.crt: %s\n' "$(cat "$OUT/workload.pem" "$OUT/root.pem" | b64)"
  printf '  tls.key: %s\n' "$(b64 "$WORK/workload.key")"     # printf is a builtin: not on any argv
  printf 'kind: Secret\nmetadata:\n  name: cluster-ca\n  namespace: cert-manager\ntype: kubernetes.io/tls\n'
} | yq 'sort_keys(..)' \
  | sops --config "$REPO/.sops.yaml" encrypt --filename-override "$SECRET_PATH" \
      --input-type yaml --output-type yaml /dev/stdin > "$OUT/cluster-ca.sops.yaml"
[[ $(yq '.data | keys | join(",")' "$OUT/cluster-ca.sops.yaml") == "ca.crt,tls.crt,tls.key" ]] || die "secret keys"
[[ $(yq '.sops.age | length' "$OUT/cluster-ca.sops.yaml") == 3 ]] || die "expected 3 recipients (admin_yubikey, admin_backup, flux)"
grep -q 'ENC\[AES256_GCM' "$OUT/cluster-ca.sops.yaml" || die "not encrypted"

# --- 6. Post-checks ---------------------------------------------------------
if [[ $MODE == yubikey ]]; then
  [[ $(yk piv keys export 82 - | sha256sum) == "$SLOT82_BEFORE" ]] || die "slot 82 changed!?"
  yk piv info | tee "$OUT/ykman-piv-info-after.txt"
fi
rm -f "$OUT/workload.csr"
( cd "$OUT"; for f in root k8s etcd front-proxy workload; do
    printf '%-12s %s\n' "$f" "$(openssl x509 -in $f.pem -noout -fingerprint -sha256 | cut -d= -f2)"; done ) | tee "$OUT/fingerprints.txt"
openssl x509 -in "$OUT/root.pem" -noout -text | sed -n '/Issuer/,/Subject:/p;/X509v3 extensions/,/Signature Algorithm/p'

cat <<EOF

Done. Nothing in $REPO was changed. Next, on a branch of the repo:
  cluster/pki/: root.pem (commit as root-ca.pem), attest-9c.pem, attest-f9.pem, fingerprints.txt   (public)
  $SECRET_PATH  <- $OUT/cluster-ca.sops.yaml
  r440: copy k8s.pem etcd.pem front-proxy.pem, run cluster-pki --ca-import.
Unplug the YubiKey.
EOF
