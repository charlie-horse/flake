# Run by ./default.nix in the build sandbox. Fails on the first broken case.
set -euo pipefail
W=$PWD/work
mkdir -p "$W"/{internal-ca,ssh-user-ca,principals,client,home}
export HOME=$W/home STEPPATH=$W/home/.step
fail() { echo "FAIL: $*" >&2; exit 1; }
step() { command step "$@"; }

# ---- CA material: what cert-manager and the sops Secret provide ------------
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout "$W/internal-ca/tls.key" -out "$W/internal-ca/tls.crt" -days 2 \
  -subj "/CN=step-ca internal CA" -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign,digitalSignature" 2>/dev/null
cp "$W/internal-ca/tls.crt" "$W/internal-ca/ca.crt"
step crypto keypair --kty OKP --crv Ed25519 --no-password --insecure -f \
  "$W/ssh-user-ca/key.pub" "$W/ssh-user-ca/key" >/dev/null 2>&1
sed "s#@WORK@#$W#g" "$caJsonPath" > "$W/ca.json"

# ---- authentik stand-in and step-ca ----------------------------------------
# agent-ci: allowed group plus one that must not become a principal.
first=${sshGroups%% *}
jq -n --arg g "$first" '{"agent-ci": ["pw-ci", [$g, "cluster-admins"]], "agent-ro": ["pw-ro", ["readers"]]}' > "$W/accounts.json"
# step-ca started while the IdP is down keeps the provisioner disabled and
# logs this line; the pod's liveness probe restarts it on that line.
step-ca "$W/ca.json" > "$W/ca-early.log" 2>&1 &
early=$!
for _ in $(seq 50); do grep -q 'failed to initialize' "$W/ca-early.log" && break; sleep 0.2; done
grep -q 'failed to initialize OIDC provisioner' "$W/ca-early.log" || { cat "$W/ca-early.log"; fail "no init-failure line when the IdP is down"; }
kill $early; wait $early || true

python3 -I "$mockIdp" "$idpPort" "$W/accounts.json" &
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$idpPort/application/o/ssh-ca/jwks/" >/dev/null && break; sleep 0.2; done
step-ca "$W/ca.json" > "$W/ca.log" 2>&1 &
for _ in $(seq 50); do
  step ca health --ca-url "https://127.0.0.1:$caPort" --root "$W/internal-ca/ca.crt" >/dev/null 2>&1 && break
  sleep 0.2
done
step ca health --ca-url "https://127.0.0.1:$caPort" --root "$W/internal-ca/ca.crt" >/dev/null || { cat "$W/ca.log"; fail "step-ca did not start"; }

# authentik's ID tokens have no jti: two minted in the same second for one
# account are identical, and step-ca refuses the second as a replay.
token() {
  sleep 1
  curl -sf -d grant_type=client_credentials -d client_id=ssh-ca -d "username=$1" -d "password=$2" \
    -d scope="openid profile" "http://127.0.0.1:$idpPort/application/o/token/" | jq -r .id_token
}
sign() { # <out-key> <token> [step flags...]
  local out=$1 tok=$2; shift 2
  step ssh certificate agent "$W/client/$out" --token "$tok" --ca-url "https://127.0.0.1:$caPort" \
    --root "$W/internal-ca/ca.crt" --no-password --insecure --no-agent --kty OKP --crv Ed25519 -f "$@" >/dev/null 2>&1
}

# ---- step-ca cases ----------------------------------------------------------
sign ok "$(token agent-ci pw-ci)" --not-after 10m --principal root || { cat "$W/ca.log"; fail "allowed agent got no cert"; }
info=$(ssh-keygen -Lf "$W/client/ok-cert.pub")
echo "$info"
principals=$(echo "$info" | sed -n '/Principals:/,/Critical Options:/p' | sed '1d;$d' | tr -d ' ')
[ "$principals" = "$first" ] || fail "principals are '$principals', want only '$first' (requested root and other groups dropped)"
echo "$info" | grep -q 'Key ID: "agent-ci"' || fail "key ID is not the account name"
exts=$(echo "$info" | sed -n '/Extensions:/,$p' | sed '1d' | tr -d ' ')
[ "$exts" = "permit-pty" ] || fail "extensions are '$exts', want only permit-pty"

tok=$(token agent-ci pw-ci)
sign once "$tok" --not-after 10m || fail "fresh token refused"
! sign replay "$tok" --not-after 10m || fail "a token was accepted twice"
! sign ro "$(token agent-ro pw-ro)" --not-after 10m || fail "account outside the allowed groups got a cert"
! sign long "$(token agent-ci pw-ci)" --not-after 3h || fail "a cert longer than $maxDuration was signed"
! sign host "$(token agent-ci pw-ci)" --host || fail "a host cert was signed"
forged=$(python3 -I -c '
import jwt, sys, time
from cryptography.hazmat.primitives.asymmetric import rsa
k = rsa.generate_private_key(public_exponent=65537, key_size=2048)
n = int(time.time())
print(jwt.encode({"iss": sys.argv[1], "aud": "ssh-ca", "sub": "x", "iat": n, "exp": n + 300,
  "preferred_username": "x", "groups": [sys.argv[2]]}, k, algorithm="RS256", headers={"kid": "k1"}))
' "http://127.0.0.1:$idpPort/application/o/ssh-ca/" "$first")
! sign forged "$forged" --not-after 10m || fail "a token signed by another key was accepted"

# ---- sshd: trust as custom.auth.sshCA sets it ---------------------------------
# Non-root sshd only logs in its own uid; `mapped` and `unmapped` share it.
uid=$(id -u) gid=$(id -g)
cat > "$W/passwd" <<P
mapped:x:$uid:$gid::$W/home:/bin/sh
unmapped:x:$uid:$gid::$W/home:/bin/sh
sshd:x:65533:65534::/var/empty:/bin/false
P
echo "users:x:$gid:" > "$W/group"
echo "$first" > "$W/principals/mapped"
# Same format as the hosts' TrustedUserCAKeys file: the CA's /ssh/roots key.
curl -sf --cacert "$W/internal-ca/ca.crt" "https://127.0.0.1:$caPort/ssh/roots" \
  | jq -r '.userKey[] | "ssh-ed25519 " + .' > "$W/user-ca.pub"
ssh-keygen -q -t ed25519 -N "" -f "$W/hostkey"
cat > "$W/sshd_config" <<C
ListenAddress 127.0.0.1:2222
HostKey $W/hostkey
PidFile $W/sshd.pid
UsePAM no
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile none
PerSourcePenalties no
TrustedUserCAKeys $W/user-ca.pub
AuthorizedPrincipalsFile $W/principals/%u
LogLevel VERBOSE
C
export NSS_WRAPPER_PASSWD=$W/passwd NSS_WRAPPER_GROUP=$W/group LD_PRELOAD=$nssWrapper
$(command -v sshd) -f "$W/sshd_config" -E "$W/sshd.log"
sleep 0.5
login() { # <user> <key> [ssh flags]
  local user=$1 key=$2; shift 2
  ssh -F /dev/null -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR -i "$key" "$@" "$user@127.0.0.1" true
}
login mapped "$W/client/ok" || { cat "$W/sshd.log"; fail "cert with a mapped principal was refused"; }
grep -q 'Accepted publickey for mapped .*ID agent-ci' "$W/sshd.log" || fail "sshd did not log the key ID"
! login unmapped "$W/client/ok" || fail "cert accepted for an account with no principals file"
cp "$W/client/ok" "$W/client/bare"; cp "$W/client/ok.pub" "$W/client/bare.pub"
! login mapped "$W/client/bare" || fail "the cert's key was accepted without the cert"
echo "step-ca test: all cases passed"
