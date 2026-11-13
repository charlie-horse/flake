#!/usr/bin/env bash
# Test for pki-files.py and the secrets guard's secrets/pki mode
# (checks.yml). Not run in CI (needs sops); run it by hand after changing
# either:
#   nix shell nixpkgs#sops nixpkgs#age -c .github/scripts/pki-files-test.sh
# Everything (a fake root, intermediates, leaves, a throwaway age key and a
# temporary .sops.yaml) is generated in a temp dir and deleted afterwards;
# no key material is ever written to the repo. PKI_TEST_REPO overrides the
# repo root (default: two levels above this script).
# shellcheck disable=SC2015,SC2094 # a && ok || fail; guard reads stdin, argv is a label
set -euo pipefail

repo=${PKI_TEST_REPO:-$(cd "$(dirname "$0")/../.." && pwd)}
check=$repo/.github/scripts/pki-files.py
def=$repo/cluster/definition.nix
for t in openssl sops age-keygen python3; do
  command -v "$t" >/dev/null || { echo "needs $t" >&2; exit 2; }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
pki=$tmp/pki
mkdir -p "$pki" keys l

# ------------------------------------------------------------ CAs
ext=$tmp/ext.cnf
cat >"$ext" <<'EOF'
[ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
[leaf]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
subjectAltName = $ENV::SANS
[leafnosan]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
export SANS=DNS:unused

openssl req -x509 -newkey rsa:2048 -nodes -keyout keys/root.key \
  -subj "/O=test/CN=test Root CA" -days 3650 -out "$pki/root-ca.pem" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
intermediate() { # name file
  openssl req -new -newkey rsa:2048 -nodes -keyout "keys/$1.key" \
    -subj "/O=test/CN=test $1 CA" -out "keys/$1.csr" 2>/dev/null
  openssl x509 -req -in "keys/$1.csr" -CA "$pki/root-ca.pem" \
    -CAkey keys/root.key -CAcreateserial -days 1825 \
    -extfile "$ext" -extensions ca -out "$pki/$2" 2>/dev/null
}
intermediate k8s k8s-ca.pem
intermediate etcd etcd-ca.pem
intermediate front-proxy front-proxy-ca.pem
intermediate workload workload-ca.pem

# leaf OUT CA_NAME CA_CERT SUBJ SANS|- DAYS: writes OUT.crt (leaf + chain
# cert CA_CERT unless it is the root) and OUT.key.
leaf() {
  local out=$1 caname=$2 cacert=$3 subj=$4 sans=$5 days=$6 sect=leaf
  if [ "$sans" = - ]; then sect=leafnosan; else export SANS=$sans; fi
  openssl req -new -newkey rsa:2048 -nodes -keyout "$out.key" \
    -subj "$subj" -out "$out.csr" 2>/dev/null
  openssl x509 -req -in "$out.csr" -CA "$cacert" -CAkey "keys/$caname.key" \
    -CAcreateserial -days "$days" -extfile "$ext" -extensions "$sect" \
    -out "$out.crt" 2>/dev/null
  [ "$caname" = root ] || cat "$cacert" >>"$out.crt"
}

# ------------------------------------------------------------ sops
age-keygen -o age.key 2>/dev/null
recipient=$(age-keygen -y age.key)
export SOPS_AGE_KEY_FILE=$tmp/age.key
cat >.sops.yaml <<EOF
creation_rules:
  - path_regex: secrets/pki/[^/]+\.yaml$
    encrypted_regex: -key\.pem$
    age: $recipient
EOF

# make CASE NODE STEM=PREFIX... : secrets/pki/NODE.yaml in cases/CASE from
# leaf files PREFIX.crt/.key, sops-encrypted with the temporary rule.
make_case() {
  local case=$1 node=$2
  shift 2
  mkdir -p "cases/$case/secrets/pki"
  local f=cases/$case/secrets/pki/$node.yaml
  python3 -I - "$f" "$@" <<'EOF'
import sys, yaml
out, pairs = sys.argv[1], sys.argv[2:]
doc = {}
for p in pairs:
    stem, src = p.split("=", 1)
    doc[f"{stem}.pem"] = open(src + ".crt").read()
    doc[f"{stem}-key.pem"] = open(src + ".key").read()
class S(yaml.SafeDumper):
    pass
S.add_representer(str, lambda d, v: d.represent_scalar(
    "tag:yaml.org,2002:str", v, style="|" if "\n" in v else None))
yaml.dump(doc, open(out, "w"), Dumper=S, sort_keys=True)
EOF
  (cd "cases/$case" && sops --config "$tmp/.sops.yaml" -e -i "secrets/pki/$node.yaml")
}

N=c4130
NODE_SANS="DNS:$N,DNS:$N.leaffish-monster.ts.net,IP:100.74.71.16,IP:10.0.0.95,IP:127.0.0.1,DNS:localhost"
leaf l/kubelet k8s "$pki/k8s-ca.pem" "/O=system:nodes/CN=system:node:$N" "$NODE_SANS" 365
leaf l/etcd-peer etcd "$pki/etcd-ca.pem" "/CN=$N" "$NODE_SANS" 365
leaf l/apiserver k8s "$pki/k8s-ca.pem" "/CN=kube-apiserver" \
  "$NODE_SANS,IP:10.0.0.200,IP:10.96.0.1,DNS:kubernetes" 365
leaf l/fp front-proxy "$pki/front-proxy-ca.pem" "/CN=front-proxy-client" - 365
leaf l/admin k8s "$pki/k8s-ca.pem" "/O=system:masters/CN=cluster-admin" - 365
good=("kubelet-$N=l/kubelet" "etcd-peer-$N=l/etcd-peer"
  "apiserver-$N=l/apiserver" "front-proxy-client-$N=l/fp" "admin-$N=l/admin")
make_case pass $N "${good[@]}"

# wrong issuer: an etcd leaf signed by the k8s CA.
leaf l/etcd-wrong k8s "$pki/k8s-ca.pem" "/CN=$N" "$NODE_SANS" 365
make_case wrong-issuer $N "${good[@]:0:1}" etcd-server-$N=l/etcd-wrong
# root-signed leaf.
leaf l/rootsigned root "$pki/root-ca.pem" "/CN=system:kube-scheduler" - 365
make_case root-signed $N "${good[@]:0:1}" scheduler-$N=l/rootsigned
# workload-signed leaf.
leaf l/workload workload "$pki/workload-ca.pem" "/CN=system:kube-proxy" - 365
make_case workload-signed $N "${good[@]:0:1}" kube-proxy-$N=l/workload
# another node's leaf: r440's kubelet cert, under its own name and under
# c4130's.
R_SANS="DNS:r440,DNS:r440.leaffish-monster.ts.net,IP:100.81.238.37,IP:10.0.0.239"
leaf l/kubelet-r440 k8s "$pki/k8s-ca.pem" "/O=system:nodes/CN=system:node:r440" "$R_SANS" 365
make_case other-node-stem $N "${good[@]:0:1}" kubelet-r440=l/kubelet-r440
make_case other-node-renamed $N "${good[@]:1:1}" kubelet-$N=l/kubelet-r440
# expiring leaf (7 days).
leaf l/expiring k8s "$pki/k8s-ca.pem" "/CN=system:kube-controller-manager" - 7
make_case expiring $N "${good[@]:0:1}" controller-manager-$N=l/expiring
# plaintext key: an encrypted file whose key is then replaced by plaintext.
make_case plaintext-key $N "${good[@]:0:2}"
python3 -I - cases/plaintext-key/secrets/pki/$N.yaml l/etcd-peer.key <<'EOF'
import sys, yaml
f, key = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(f))
doc["etcd-peer-c4130-key.pem"] = open(key).read()
yaml.safe_dump(doc, open(f, "w"))
EOF
# a missing key file (cert without its -key.pem).
make_case missing-key $N "${good[@]:0:1}"
python3 -I - cases/missing-key/secrets/pki/$N.yaml l/admin.crt <<'EOF'
import sys, yaml
f, crt = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(f))
doc["admin-c4130.pem"] = open(crt).read()
yaml.safe_dump(doc, open(f, "w"))
EOF
# a private key smuggled into a cert value.
make_case key-in-cert $N "${good[@]:0:1}"
python3 -I - cases/key-in-cert/secrets/pki/$N.yaml l/admin.crt l/admin.key <<'EOF'
import sys, yaml
f, crt, key = sys.argv[1:]
doc = yaml.safe_load(open(f))
doc["admin-c4130.pem"] = open(crt).read() + open(key).read()
doc["admin-c4130-key.pem"] = doc["kubelet-c4130-key.pem"]
yaml.safe_dump(doc, open(f, "w"))
EOF

# ------------------------------------------------------------ run
# The guard's sops-file program, taken from checks.yml as CI runs it.
python3 -I - "$repo/.github/workflows/checks.yml" guard.py <<'EOF'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for step in wf["jobs"]["secrets-guard"]["steps"]:
    run = step.get("run") or ""
    if "secrets/pki/*.yaml) mode=pki" in run:
        prog = run.split("python3 -I -c '", 1)[1].split("\n' \"$mode\"", 1)[0]
        open(sys.argv[2], "w").write(prog)
        break
else:
    sys.exit("guard program not found in checks.yml")
EOF

fail=0
expect() { # want(pass|fail) case
  local want=$1 case=$2 got out gout gstatus=pass
  out=$(python3 -I "$check" --pki-dir "$pki" --definition "$def" \
    "cases/$case/secrets/pki/$N.yaml" 2>&1) && got=pass || got=fail
  local f="cases/$case/secrets/pki/$N.yaml"
  gout=$(python3 -I guard.py pki "$f" <"$f" 2>&1) || gstatus=fail
  if [ "$got" = "$want" ]; then
    echo "ok    $case: pki-files $got (expected)"
  else
    echo "FAIL  $case: pki-files $got, expected $want"
    fail=1
  fi
  sed 's/^/        /' <<<"$out"
  echo "      guard: $gstatus${gout:+ ($gout)}"
}
expect pass pass
for c in wrong-issuer root-signed workload-signed other-node-stem \
  other-node-renamed expiring plaintext-key missing-key key-in-cert; do
  expect fail "$c"
done
# The guard must reject the plaintext key and accept the rest.
python3 -I guard.py pki x <cases/plaintext-key/secrets/pki/$N.yaml >/dev/null \
  && { echo "FAIL  guard accepted a plaintext key"; fail=1; } \
  || echo "ok    guard rejects the plaintext key"
python3 -I guard.py pki x <cases/key-in-cert/secrets/pki/$N.yaml >/dev/null \
  && { echo "FAIL  guard accepted a key inside a cert value"; fail=1; } \
  || echo "ok    guard rejects a key inside a cert value"
python3 -I guard.py pki x <cases/pass/secrets/pki/$N.yaml >/dev/null \
  && echo "ok    guard accepts plaintext certs" \
  || { echo "FAIL  guard rejected plaintext certs"; fail=1; }
python3 -I guard.py strict x <cases/pass/secrets/pki/$N.yaml >/dev/null \
  && { echo "FAIL  guard accepted plaintext certs outside secrets/pki"; fail=1; } \
  || echo "ok    guard rejects plaintext certs outside secrets/pki (strict mode)"
# No files: skips cleanly.
(mkdir -p empty && cd empty && python3 -I "$check" --pki-dir "$pki" \
  --definition "$def") && echo "ok    no files: skipped" \
  || { echo "FAIL  no files"; fail=1; }

exit "$fail"
