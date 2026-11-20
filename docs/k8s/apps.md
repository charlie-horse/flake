# Kubernetes apps: operating them

Procedures for the in-cluster apps. What each app runs, where, and with
which settings: read its component under `k8s/components/`. Layout, render,
Flux and bootstrap: [README.md](README.md). Changing a Secret value:
[secrets.md](secrets.md#changing-a-value-rotation).

## cert-manager

Workloads get TLS from the ClusterIssuer `cluster-ca` (the workload
intermediate under the YubiKey root, Secret `cert-manager/cluster-ca` from
sops). The cluster's own certificates come from the `cluster-pki` Issuers
instead ([../pki.md](../pki.md)).

### Requesting a certificate

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: myapp-tls
  namespace: myapp
spec:
  secretName: myapp-tls           # gets tls.crt, tls.key and ca.crt (the root)
  dnsNames:
    - myapp.myapp.svc
    - myapp.myapp.svc.cluster.local
  privateKey: { algorithm: ECDSA, size: 256 }
  issuerRef: { group: cert-manager.io, kind: ClusterIssuer, name: cluster-ca }
```

Rules:

- As a catenix component it is
  `resources."cert-manager.io".v1.Certificate.<name>`, which needs the
  cert-manager CRDs imported (as `components/infra/cert-manager/issuers.nix`
  does), and the component must be **deferred**
  ([README.md](README.md#deferred-components)).
- Keep durations under the intermediate's remaining life.
- `cluster-ca` is for in-cluster TLS only; public hostnames go through the
  [Cloudflare tunnel](#cloudflare-tunnel). Clients trust `ca.crt` from any
  issued Secret, or `cluster/pki/root-ca.pem`.
- Anyone who may create a Certificate may get any non-CA name signed by
  `cluster-ca`.

### Renewing the intermediate

Nothing renews `cert-manager/cluster-ca`. Before it expires
(`sops decrypt --extract '["data"]["tls.crt"]' k8s/secrets/cert-manager/cluster-ca.sops.yaml | base64 -d | openssl x509 -noout -enddate`):
get a new signature from the root ([../pki.md](../pki.md)), then edit the
sops file, PR, merge. Without the Secret only `cluster-ca` (and the
Kustomization `cert-manager-issuers`) is NotReady.

Removing `infra/cert-manager` removes its CRDs and with them every
Certificate and Issuer in the cluster, the `cluster-pki` Issuers included.

## authentik

SSO (OIDC) for people. The cluster never depends on it: if authentik is
down, only OIDC logins fail; the break-glass is
`sudo kubectl --kubeconfig /etc/kubernetes/admin.kubeconfig` on any node
([../pki.md](../pki.md)). Database backups: `pg_dump -Fc` files in the
backup volume declared in `components/apps/authentik/backup.nix`.

Give `akadmin` a strong password plus MFA (the admin UI is public), and add
real users rather than sharing it. Without the tunnel:

```sh
kubectl -n authentik port-forward svc/authentik-server 9000:80
```

If a flow's slug changes in the authentik UI, change it in
`components/apps/authentik/blueprints/*.yaml` too, or the blueprints stop
reconciling.

### The Secret (authentik/authentik-secrets)

- `AUTHENTIK_SECRET_KEY`: never change it once authentik has started.
- `AUTHENTIK_POSTGRESQL__PASSWORD`: set the new password in the database
  first (`ALTER ROLE authentik PASSWORD …` in `psql` in the postgres pod,
  typed in, not on a command line), then in the file; merge, then restart
  `authentik-server` and `authentik-worker`. Logins fail in between.
- `AUTHENTIK_BOOTSTRAP_PASSWORD`: `akadmin`'s password, used on the first
  start only. Read it with
  `sops decrypt --extract '["data"]["AUTHENTIK_BOOTSTRAP_PASSWORD"]' k8s/secrets/authentik/authentik-secrets.sops.yaml | base64 -d`
  (or `kubectl -n authentik get secret authentik-secrets -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_PASSWORD}' | base64 -d`),
  then change it in the UI.

New values: `openssl rand -base64 60 | tr -d "\n"` (secret key),
`openssl rand -hex 32 | tr -d "\n"` (database),
`openssl rand -base64 24 | tr -d "\n/+="` (bootstrap), each piped into
`base64 -w0 | jq -R . | sops set --value-stdin` as in
[secrets.md](secrets.md#changing-a-value-rotation).

### Cluster login (kube-apiserver OIDC)

Members of the authentik group `cluster-admins` are cluster-admin when they
log in with OIDC (usernames and groups get the `oidc:` prefix). The
issuers the apiservers trust are the `oidc` entry in
`cluster/definition.nix`; changing it means switching every control plane,
one at a time. To log in, add yourself to `cluster-admins` in authentik,
then on your machine:

```sh
kubectl krew install oidc-login   # or nixpkgs#kubelogin-oidc
kubectl config set-credentials neurosis-oidc \
  --exec-api-version=client.authentication.k8s.io/v1 \
  --exec-interactive-mode=IfAvailable \
  --exec-command=kubectl --exec-arg=oidc-login --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://auth.neuros.is/application/o/kubernetes/ \
  --exec-arg=--oidc-client-id=kubernetes \
  --exec-arg=--oidc-extra-scope=profile --exec-arg=--oidc-extra-scope=email \
  --exec-arg=--oidc-extra-scope=offline_access
kubectl --user=neurosis-oidc auth whoami   # oidc:<username>, groups oidc:cluster-admins
```

kubelogin serves its login page on `http://localhost:8000` (or `:18000`)
on the machine running kubectl. When kubectl runs over SSH, forward the
port first: `ssh -L 8000:localhost:8000 <host>`. Older kubectl without
`--exec-interactive-mode`: add `interactiveMode: IfAvailable` under the
user's `exec:` in the kubeconfig by hand.

## Headlamp

Log in with authentik (group `cluster-admins`); a user sees what their
`oidc:` groups allow.

### The Secret (headlamp/headlamp-oidc)

Key `OIDC_CLIENT_SECRET`: the client secret authentik generated for the
provider `headlamp` (Applications → Providers → `headlamp`; generate
nothing here). If authentik's secret changes, paste the new one into
`k8s/secrets/headlamp/headlamp-oidc.sops.yaml`
([secrets.md](secrets.md#changing-a-value-rotation), the `read -rs` line),
merge, then `kubectl -n headlamp rollout restart deploy/headlamp`.

Without the tunnel: `kubectl -n headlamp port-forward svc/headlamp 4466:80`
(the OIDC callback still points at the public host, so log in there).

## Cloudflare tunnel

Every public hostname goes through one locally managed tunnel
(`cluster.tunnel` in `cluster/definition.nix`), run in the cluster by
`components/apps/cloudflared/`; routes are in `files.nix`.

- **New hostname.** Add it to `routes` in
  `components/apps/cloudflared/files.nix` (with its `host`/`serviceIP` in
  `cluster/definition.nix`), merge, then add its DNS route.
- **DNS route.** A proxied CNAME to `<tunnel id>.cfargotunnel.com`, made
  with the Cloudflare account cert ([../secrets.md](../secrets.md)), as
  admin on c4130:
  `cloudflared tunnel route dns --overwrite-dns <tunnel id> <hostname>`.
- **Credential** (Secret `cloudflared/tunnel-credentials`, key
  `credentials.json`, the JSON `cloudflared tunnel create` wrote). To
  replace it, on a machine with the JSON:

  ```sh
  base64 -w0 < <path to the JSON> | jq -R . \
    | sops set --value-stdin k8s/secrets/cloudflared/tunnel-credentials.sops.yaml '["data"]["credentials.json"]'
  ```

  then PR, merge, `kubectl -n cloudflared rollout restart deploy/cloudflared`
  (a new tunnel id also goes in `cluster.tunnel`).
- Keep nginx replacing `X-Forwarded-For` with `Cf-Connecting-Ip`, and keep
  authentik's trusted proxy CIDRs limited to the nodes' own addresses, or
  clients can forge their IP.

## Open WebUI

Log in with the local form or **Continue with authentik** (members of the
authentik group `local-ai`). New SSO users get the instance's default
role; roles are never taken from authentik.

The Secret `open-webui/open-webui-secrets`:
`WEBUI_SECRET_KEY` (changing it logs everyone out) and
`OAUTH_CLIENT_SECRET` (authentik's generated secret for the provider
`open-webui`). After a change:
`kubectl -n open-webui rollout restart deploy/open-webui`.

## step-ca

Short-lived OpenSSH user certificates for automations. An automation is an
authentik service account in a group from `sshGroups`
(`components/apps/step-ca/settings.nix`, also created by the blueprint
`ssh-ca.yaml`); the certificate's principals are those groups. People log
in with their own keys or with idp-pam; this is for non-interactive
callers.

Rules:

- Mint tokens through `https://auth.neuros.is`: authentik sets the
  token's issuer from the request's host, and step-ca accepts only that
  issuer.
- One token per certificate. Tokens carry no `jti`; two minted in the same
  second for one account are identical and step-ca refuses the second.
- Keep `sshGroups`, the blueprint's groups and the hosts' `principals` in
  step: a group is a principal only if all three name it.
- The CA key never leaves tmpfs unencrypted; generate it only as below.

### Creating the SSH user CA key

Once, before the first deploy, on a machine with a checkout:

```sh
nix shell .#ca-ceremony-tools          # step, sops, yq
d=$(mktemp -d -p /dev/shm); f=k8s/secrets/step-ca/ssh-user-ca.sops.yaml; mkdir -p k8s/secrets/step-ca
step crypto keypair --kty OKP --crv Ed25519 --no-password --insecure "$d/pub" "$d/key"
k=$(base64 -w0 < "$d/key") yq -n '.apiVersion = "v1" | .data.key = strenv(k) | .kind = "Secret" | .metadata.name = "ssh-user-ca" | .metadata.namespace = "step-ca" | .type = "Opaque" | sort_keys(..)' \
  | sops encrypt --filename-override "$f" --input-type yaml --output-type yaml /dev/stdin > "$f"
step crypto key format --ssh "$d/pub"  # the public half, for custom.auth.sshCA.userCAKeys
shred -u "$d"/*; rmdir "$d"
```

PR, merge. Until the Secret exists the step-ca pod cannot start.

### Trusting it on a host

In the host's configuration:

```nix
custom.auth.sshCA = {
  enable = true;
  userCAKeys = [ "ssh-ed25519 AAAA…" ];   # the public half from above
  principals.<account> = [ "ssh-admins" ];
};
```

Switch the host ([../cluster.md](../cluster.md#changing-a-host)). Its sshd
needs no access to step-ca. To rotate the CA key: add the new public half
to `userCAKeys`, switch every host, replace the Secret, then remove the old
half and switch again.

### Adding an automation

In authentik: Directory → Users → Create Service account, add it to the group, then create an app password for it
(Directory → Tokens and App passwords). Give the automation the username
and app password through its own secret store.

### Getting a certificate

From a node or a pod (the Service is `cluster.stepCa.serviceIP`):

```sh
tok=$(curl -sf https://auth.neuros.is/application/o/token/ \
  -d grant_type=client_credentials -d client_id=ssh-ca -d "username=$USER_NAME" \
  --data-urlencode "password@$APP_PASSWORD_FILE" -d scope="openid profile" | jq -r .id_token)
step ssh certificate "$USER_NAME" ./id_ed25519 --token "$tok" \
  --ca-url "https://$STEP_CA_IP" --root cluster/pki/root-ca.pem \
  --kty OKP --crv Ed25519 --no-password --insecure --no-agent --not-after 15m
ssh -i ./id_ed25519 <account>@<host>
```

`STEP_CA_IP` is `cluster.stepCa.serviceIP`. Inspect a
certificate with `ssh-keygen -Lf ./id_ed25519-cert.pub`; sshd logs its key
ID (the service account's name).
