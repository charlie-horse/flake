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
  [Cloudflare tunnel](#cloudflare-tunnel) or, served without it, get a
  [Let's Encrypt](#public-certificates-lets-encrypt) certificate. Clients
  trust `ca.crt` from any issued Secret, or `cluster/pki/root-ca.pem`.
- Anyone who may create a Certificate may get any non-CA name signed by
  `cluster-ca`.

### Public certificates (Let's Encrypt)

The ClusterIssuers `letsencrypt-staging` and `letsencrypt-production`
(`components/infra/cert-manager/acme.nix`) solve ACME DNS-01 through
Cloudflare with the token in the Secret `cert-manager/cloudflare-api-token`.
Request as [above](#requesting-a-certificate), with
`issuerRef: { group: cert-manager.io, kind: ClusterIssuer, name: letsencrypt-staging }`
until the certificate is Ready, then `letsencrypt-production`.

Rules:

- `dnsNames` only, each `neuros.is` or under it (wildcards such as
  `*.at.neuros.is` included); no `commonName`, IPs, URIs, subject or
  usages beyond `digital signature`, `key encipherment`, `server auth`.
  approver-policy denies anything else and the request stays unapproved.
- A certificate here does not reach clients of a proxied (orange-cloud)
  Cloudflare record: they see Cloudflare's edge certificate. It serves a
  DNS-only record pointing at something that terminates TLS with the
  Secret.
- Let's Encrypt rate-limits production (duplicate certificates, failed
  validations): debug against staging.

Status: `kubectl get clusterissuer`, `kubectl -n <ns> describe certificate <name>`,
then `kubectl -n <ns> get challenges` while a DNS-01 challenge is pending.

#### The Cloudflare API token

The Secret `cert-manager/cloudflare-api-token` (key `api-token`), read by
the issuers and by the [Dynamic DNS](#dynamic-dns) Job. Without it the
issuers are Ready (account registration needs no token) but every challenge
fails, and the `ddns` Jobs fail. To create or replace it:

1. Cloudflare dashboard, My Profile → API Tokens → Create Token → Custom
   token. Permissions: Zone / DNS / Edit and Zone / Zone / Read. Zone
   Resources: Include / Specific zone / `neuros.is`. Set an expiry and
   note it.
2. On a machine with an admin sops identity
   ([secrets.md](secrets.md#changing-a-value-rotation)), on a branch, paste
   the token at the prompt:

   ```sh
   nix shell nixpkgs#sops nixpkgs#yq-go
   f=k8s/secrets/cert-manager/cloudflare-api-token.sops.yaml
   read -rs t && t=$(printf %s "$t" | base64 -w0) yq -n \
     '.apiVersion = "v1" | .data["api-token"] = strenv(t) | .kind = "Secret" | .metadata.name = "cloudflare-api-token" | .metadata.namespace = "cert-manager" | .type = "Opaque" | sort_keys(..)' \
     | sops encrypt --filename-override "$f" --input-type yaml --output-type yaml /dev/stdin > "$f"; unset t
   ```

   The same lines replace it.
3. PR, merge. cert-manager and each `ddns` Job read the Secret when they
   use it; no restart. Revoke the old token in Cloudflare after a
   replacement is applied.

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

## Dynamic DNS

`components/apps/ddns/` runs a CronJob (namespace `cert-manager`) every 5 minutes that keeps the
DNS-only (unproxied) A records in its `records` on the network's public
IPv4, with the token in `cert-manager/cloudflare-api-token`
([above](#the-cloudflare-api-token)). The router forwards TCP 443 to
r440's LAN address (`cluster.nodes.r440.lanIP`); while r440 is down, nothing
answers on public 443. Every node accepts 443 (`modules/cluster/firewall.nix`).

Rules:

- A name in `records` must not also be a tunnel route or a proxied record
  in Cloudflare: the Job fails while a name has more than one A record, and
  does not touch CNAMEs.
- Removing a name from `records` leaves its record in Cloudflare; delete it
  in the dashboard.

Status: `kubectl -n cert-manager get jobs`,
`kubectl -n cert-manager logs job/<job>`. To run it now:
`kubectl -n cert-manager create job --from=cronjob/ddns ddns-now`.

## Open WebUI

Log in with the local form or **Continue with authentik** (members of the
authentik group `local-ai`). New SSO users get the instance's default
role; roles are never taken from authentik.

The Secret `open-webui/open-webui-secrets`:
`WEBUI_SECRET_KEY` (changing it logs everyone out) and
`OAUTH_CLIENT_SECRET` (authentik's generated secret for the provider
`open-webui`). After a change:
`kubectl -n open-webui rollout restart deploy/open-webui`.

## ATProto services

Tranquil PDS, the Tangled knot and ATCR, in the namespace `atproto`
(`components/apps/atproto/`). Each host in `cluster/definition.nix` needs
its DNS route ([Cloudflare tunnel](#cloudflare-tunnel)); PDS handles go
through the [TLS edge](#atproto-tls-edge) instead.

Images: Tranquil PDS, the knot and ATCR's AppView and hold are built from
`pkgs/atproto-images/` and pushed to `ghcr.io/charlie-horse/flake/<image>`
by `.github/workflows/atproto-images.yml` on `main`. A component whose
`digest` is `null` runs no pods. To deploy or update one: merge the image
change, run or wait for the workflow, copy the digest from its summary
into `digest` in the component, PR, merge.

### Tranquil PDS

Log in at `https://pds.neuros.is/app/` with a password or passkey, or with
**authentik** (group `pds-users`). New accounts need an invite code; the
first comes from
`kubectl -n atproto logs deploy/tranquil-pds | grep 'Bootstrap invite'`,
and the first account is admin (it mints further invites in the UI).
Choose did:web at signup for a DID of `did:web:<handle>`, which the PDS
serves; the owner of the knot and the hold is `adminDid` in
`cluster/definition.nix`.
Handles are `<name>.at.neuros.is`, served by the
[TLS edge](#atproto-tls-edge), not the tunnel: Cloudflare's Universal SSL
covers one level (`*.neuros.is`) only.

- **authentik client secret.** authentik's provider `tranquil-pds` must
  carry the client secret from the Secret: Applications → Providers →
  `tranquil-pds` → Client Secret, paste the output of
  `sops decrypt --extract '["data"]["SSO_OIDC_CLIENT_SECRET"]' k8s/secrets/atproto/tranquil-pds-secrets.sops.yaml | base64 -d`.
  The blueprint never sets it.
- **The Secret `atproto/tranquil-pds-secrets`:** `JWT_SECRET`, `DPOP_SECRET`
  (changing either logs everyone out), `MASTER_KEY` (encrypts the account
  signing keys: never change it), `POSTGRES_PASSWORD` (change it in the
  database first, as for authentik), `SSO_OIDC_CLIENT_SECRET` (set the new
  value in authentik too). After a change:
  `kubectl -n atproto rollout restart deploy/tranquil-pds`.
- Without the tunnel: `kubectl -n atproto port-forward svc/tranquil-pds 3000:80`.
- Back up the database (`pg_dump -Fc` in `tranquil-pds-postgresql-0`) and
  `/var/lib/tranquil-pds` on r440.

### ATProto TLS edge

Public HTTPS for PDS handles (`https://<name>.at.neuros.is`): handle
resolution and did:web documents only, served by the DaemonSet in
`components/apps/atproto-edge/` on r440's LAN address, port 443, with the Let's Encrypt
certificate `atproto-edge/at-wildcard-tls`.

- Router: forward TCP 443 to r440's `lanIP`. While r440 is down, handles
  don't resolve.
- Cloudflare DNS: `*.at.neuros.is` A record, DNS only (not proxied), to the
  public address.
- Certificate and renewal:
  `kubectl -n atproto-edge get certificate at-wildcard-tls` (Ready True;
  `kubectl describe` shows Not After and Renewal Time). nginx reloads a
  renewed certificate within 5 minutes; check with
  `openssl s_client -connect <r440 lanIP>:443 -servername charlie.at.neuros.is </dev/null 2>/dev/null | openssl x509 -noout -dates`.
- Smoke test from outside:
  `curl https://charlie.at.neuros.is/.well-known/atproto-did` returns the
  DID; any other path returns 404.

### Tangled knot

- Health: `curl https://knot.neuros.is/xrpc/_health`; relay check:
  `kubectl -n atproto exec deploy/tangled-knot -- knot-server doctor`.
- Register: tangled.org → Settings → Knots → add `knot.neuros.is`, signed
  in as the owner DID set in `components/apps/atproto/tangled/`. If no relay
  has picked the knot up:
  `curl -X POST https://index.tangled.network/xrpc/com.atproto.sync.requestCrawl -H 'Content-Type: application/json' -d '{"hostname":"knot.neuros.is"}'`.
- Git over HTTPS (clone, fetch) works through the tunnel; SSH does not
  reach the knot through `knot.neuros.is`.
- `atproto/tangled-knot-secrets`, key `KNOT_MASTER_KEY`: unseals
  `/var/lib/tangled-knot/sealed-keys` on r440. Never change it: a new key
  cannot open the existing sealed keys.
- Back up `/var/lib/tangled-knot` on r440 (repos, LFS, sealed keys, SSH
  host key).

### ATCR

Push and pull as `cr.neuros.is/<handle>/<repo>`; log in with
`docker login cr.neuros.is` (an ATProto handle and an app password from
that account's PDS). Pulls are anonymous. Only the hold's captain
(`ownerDid` in `components/apps/atproto/atcr/hold.nix`) and its crew may
push; manage crew and storage at `https://hold.neuros.is/admin`.

- **Layers over 100 MB** fail through Cloudflare. Push them through a
  port-forward instead:
  `kubectl -n atproto port-forward svc/atcr-appview 5000:80`, then push to
  `localhost:5000/<handle>/<repo>`.
- **The Secret `atproto/atcr-secrets`:** `GARAGE_RPC_SECRET`,
  `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`. Garage imports the S3 key on
  its first start only: to change it, create a new key with
  `kubectl -n atproto exec deploy/atcr-garage -- /garage key …`, allow it on
  the bucket `atcr-blobs`, then put it in the file. After a change:
  `kubectl -n atproto rollout restart deploy/atcr-garage deploy/atcr-hold`.
- Health: `curl https://hold.neuros.is/xrpc/_health`,
  `curl https://cr.neuros.is/v2/`.
- Back up `/var/lib/atcr` on r440 (blobs, signing and OAuth keys). Tags and
  manifests live in each owner's PDS.

## LLDAP

No public hostname. Web UI: `kubectl -n lldap port-forward svc/lldap 17170:17170`,
then http://localhost:17170, user `admin`. In-cluster LDAP:
`ldap://lldap.lldap.svc.cluster.local:3890`, base DN `dc=neuros,dc=is`,
bind DN `uid=admin,ou=people,dc=neuros,dc=is`. Give LDAP clients their own
user in the group `lldap_strict_readonly`, not the admin.

The Secret `lldap/lldap-secrets`:

- `LLDAP_LDAP_USER_PASS`: the admin password, used on the first start only.
  Read it with
  `sops decrypt --extract '["data"]["LLDAP_LDAP_USER_PASS"]' k8s/secrets/lldap/lldap-secrets.sops.yaml | base64 -d`,
  then change it in the UI. To force it back to the file's value, set
  `LLDAP_FORCE_LDAP_USER_PASS_RESET=true` for one start.
- `LLDAP_KEY_SEED`: never change it once LLDAP has started (stored
  passwords depend on it).
- `LLDAP_JWT_SECRET`: changing it logs everyone out.

New values: `openssl rand -base64 48 | tr -d "\n"`. After a change:
`kubectl -n lldap rollout restart deploy/lldap`. Removing the component
leaves `/var/lib/lldap/data` on r440 (PV reclaim Retain); delete it by hand.
