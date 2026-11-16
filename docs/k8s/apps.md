# Kubernetes apps: cert-manager, authentik, Headlamp, tunnel, Open WebUI

The in-cluster services people and workloads use. Layout, render, Flux and
bootstrap: [README.md](README.md). Their Secrets and how to rotate them:
[secrets.md](secrets.md). Public hostnames all go through one Cloudflare
tunnel ([Cloudflare tunnel](#cloudflare-tunnel)).

## cert-manager

The workload PKI (`components/infra/cert-manager/`): TLS for things that run
**in** the cluster. The cluster's own certificates (etcd, apiservers,
kubelets, …) come from the Issuers in namespace `cluster-pki`, not from
`cluster-ca`, and the hosts read them as sops files
([../pki.md](../pki.md#bootstrap-pki-and-workload-pki)).

| File | What |
| --- | --- |
| `chart.nix` | controller and cainjector (1 replica each, leader-elected), webhook (2 replicas on different nodes, PDB `minAvailable: 1`; c4130 is tainted, so r440 and m2mini), CRDs; built-in auto-approver off (`disableAutoApproval`), no Prometheus, no `startupapicheck` hook |
| `approver-policy.nix` | cert-manager approver-policy, the **only** approver: a request no CertificateRequestPolicy allows is never signed. 1 replica; while it is down, renewals wait and certs in use are untouched |
| `issuers.nix` | component `infra/cert-manager-issuers` (deferred): ClusterIssuer `cluster-ca`, its policy, the `use` grant |
| `crds.nix` | the two charts' CRDs, to type the deferred components' objects |
| `settings.nix` | names shared by all of them |

| Object | What |
| --- | --- |
| Secret `cert-manager/cluster-ca` | the workload intermediate CA "neurosis workload CA" (ECDSA P-384, 2 y), signed by the YubiKey root: `tls.crt` = intermediate + root, `tls.key` (made in tmpfs at the root CA ceremony and sops-encrypted from there), `ca.crt` = root (`cluster/pki/root-ca.pem`). Expires 2028-11-12. Sops-encrypted in git at `k8s/secrets/cert-manager/cluster-ca.sops.yaml`, applied by the Kustomization `secrets` |
| ClusterIssuer **`cluster-ca`** | CA issuer over that Secret: **what workloads use** |
| CertificateRequestPolicy `cluster-ca` | allows any subject, SAN and usage for `cluster-ca`, but no CA certificate (`isCA: false`; the intermediate is `pathlen:0`) |
| ClusterRole/Binding `cert-manager-policy:cluster-ca` | `use` of that policy for cert-manager's controller ServiceAccount |

Only the ClusterIssuer and its policy are declared in the component. The
Secret comes from sops, and the Kustomization `secrets` owns it
(`prune: true`; hand edits are reverted), like every sops Secret
([secrets.md](secrets.md)). No Certificate points at it, so cert-manager
does not renew it. **Renewal**, before the 2028-11-12 expiry: a new
signature from the root
([../pki.md, Signing an intermediate](../pki.md#signing-an-intermediate-under-the-existing-root)),
then `sops` edit, PR, merge. Without the Secret the ClusterIssuer (and the
Kustomization `cert-manager-issuers`, which `wait`s) is NotReady and
nothing else breaks. The key is readable by the admin sops identities and
Flux's age key, and a backup of the etcd data holds it, like every Secret.

The issuer objects are a deferred component, like every `cert-manager.io`
object ([README.md, Deferred components](README.md#deferred-components)).

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

As a catenix component: `resources."cert-manager.io".v1.Certificate.<name>`,
which needs the cert-manager CRDs imported to type-check (see `issuers.nix`:
`catenix.crdModule` over `crds.nix`), and the component must be
**deferred**, as everything `cert-manager.io` is. Defaults: 90 days,
renewed at 2/3; keep durations under the intermediate's remaining life.
Clients that should trust these certificates use `ca.crt` from any issued
Secret, or the root, `cluster/pki/root-ca.pem` (public, in git).

**Who can get what signed.** approver-policy approves a request for
`cluster-ca` when the policy `cluster-ca` allows it and the requester may
`use` that policy. Certificates are turned into CertificateRequests by
cert-manager's controller, which holds that `use` grant, so whoever may
create a Certificate in any namespace may get any non-CA name signed by
`cluster-ca`: cluster admins and Flux. Nothing outside the cluster trusts
`cluster-ca`: it is for in-cluster TLS, not public hostnames (those go
through the Cloudflare tunnel).

### Webhook and network

The apiserver calls the webhook (`cert-manager/cert-manager-webhook`, port
443 → pod 10250) through its ClusterIP, with no aggregator routing.
kube-proxy on the apiserver's node DNATs it to a webhook pod and, the source
being outside `podCidr`, masquerades it to that node's flannel address;
VXLAN carries it to the pod's node (udp/8472 between LAN IPs, open on every
node by `modules/cluster/firewall.nix`, c4130 included, whatever
`trustTailscale`), and the reply returns on the same connection. The NixOS
firewall filters only INPUT, not forwarded pod traffic. The webhook's own
serving cert is
self-managed (Secret `cert-manager-webhook-ca`, injected into the webhook
configurations by the cainjector), so it does not depend on `cluster-ca`.

### Removing it

Deleting the ClusterIssuer, or the whole component, leaves the Secret
`cluster-ca`. Deleting its sops file deletes the Secret (prune), but the
key stays recoverable from git history with an admin identity. A new
intermediate is signed by the root
([../pki.md, CA rotation](../pki.md#ca-rotation)). Removing
`infra/cert-manager` removes its CRDs and with them every Certificate and
Issuer in the cluster, the `cluster-pki` Issuers included.

## authentik

SSO for the cluster and its apps (`components/apps/authentik/`). The
cluster never depends on it: kubelets, the control plane and the admin
kubeconfig authenticate with x509 certs, Flux and pods with
service-account tokens. If authentik is down, only OIDC logins fail; the
break-glass is
`sudo kubectl --kubeconfig /etc/kubernetes/admin.kubeconfig` on any node
([../pki.md, Break-glass](../pki.md#break-glass)).

| Piece (file) | Where | Data |
| --- | --- | --- |
| `authentik-server`, `authentik-worker` (`chart.nix`, authentik chart) | one of each per node (required anti-affinity; tolerates c4130's GPU taint), so login survives any one node being down; rolling update `maxSurge: 0` | none |
| `authentik-postgresql` (`postgres.nix`, StatefulSet, `postgres:17.11-trixie`) | m2mini (PV node affinity) | `m2mini:/var/lib/authentik/postgres` |
| `authentik-backup` (`backup.nix`, CronJob 03:17 America/New_York) | r440 (PV node affinity) | `r440:/var/lib/authentik/backup/authentik-*.dump` (`pg_dump -Fc`, newest 14) |
| blueprints (`blueprints.nix`, `blueprints/*.yaml`, ConfigMap `authentik-blueprints`) | applied by the worker | OIDC clients and groups ([below](#cluster-login-kube-apiserver-oidc)) |

The namespace enforces `baseline` (the postgres entrypoint starts as root
and drops privileges) and warns on `restricted`; server and worker meet
`restricted`. The PVs are hostPath (`DirectoryOrCreate`, reclaim
`Retain`): deleting the claim or the component never deletes data.

### The Secret (authentik/authentik-secrets)

The pods read `authentik/authentik-secrets`, sops-encrypted in
`k8s/secrets/authentik/authentik-secrets.sops.yaml` and applied by the
Kustomization `secrets` ([secrets.md](secrets.md): how to change a value).
Until it is applied (e.g. on a fresh cluster before `sops-age` exists) the
pods sit in `CreateContainerConfigError`; they start by themselves once it
is, and nothing else is affected.

- `AUTHENTIK_SECRET_KEY` signs sessions and encrypts stored secrets. Never
  change it once authentik has started.
- `AUTHENTIK_POSTGRESQL__PASSWORD` is also the database's
  `POSTGRES_PASSWORD`. That variable only takes effect on the first start
  with an empty data dir. To change it, set the new password in the
  database first (`ALTER ROLE authentik PASSWORD …` in `psql` in the
  postgres pod, typed in, not on a command line), then in the file; merge,
  then restart `authentik-server` and `authentik-worker`. Logins fail in
  between.
- `AUTHENTIK_BOOTSTRAP_PASSWORD` is `akadmin`'s password, set on the first
  start only (changing it later does nothing). Read it with
  `sops decrypt --extract '["data"]["AUTHENTIK_BOOTSTRAP_PASSWORD"]' k8s/secrets/authentik/authentik-secrets.sops.yaml | base64 -d`
  (or from the live Secret:
  `kubectl -n authentik get secret authentik-secrets -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_PASSWORD}' | base64 -d`),
  then change it in the UI.

New values, when one is needed: `openssl rand -base64 60 | tr -d "\n"`
(secret key), `openssl rand -hex 32 | tr -d "\n"` (database),
`openssl rand -base64 24 | tr -d "\n/+="` (bootstrap), each piped into
`base64 -w0 | jq -R . | sops set --value-stdin` as in
[secrets.md, Changing a value](secrets.md#changing-a-value-rotation).

### Reaching it

Public: **https://auth.neuros.is** (`cluster.authentik.host`), through the
cluster's Cloudflare tunnel, to Service `authentik-server` at its fixed
ClusterIP (`cluster.authentik.serviceIP`, 10.96.0.20, in the static band of
the service CIDR). authentik trusts `X-Forwarded-*` only from the tunnel's
proxies (`AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS`): each node's cni0 /
flannel.1 address (`10.244.N.0/31`), the nodes' LAN IPs and loopback.
Ordinary pods get `.2` and up, so they cannot forge client IPs.
`X-Forwarded-Proto` must stay trusted from the proxies, or the issuer would
be `http://`.

The admin UI is public too: give `akadmin` a strong password plus MFA, and
add real users rather than sharing it. Without the tunnel:

```sh
kubectl -n authentik port-forward svc/authentik-server 9000:80
```

### Cluster login (kube-apiserver OIDC)

The blueprints create:

- the group `cluster-admins`;
- the public OAuth2/OIDC provider `kubernetes` (client id `kubernetes`,
  PKCE, RS256 with authentik's self-signed key, redirect
  `http://localhost:8000` and `:18000` for kubelogin) and the application
  `kubernetes`, which only `cluster-admins` may use;
- the confidential provider and application `headlamp` (client id
  `headlamp`, redirect `https://k8s.neuros.is/oidc-callback`), also
  `cluster-admins` only ([Headlamp](#headlamp));
- the group `local-ai` and the confidential provider and application
  `open-webui`, which only `local-ai` may use ([Open WebUI](#open-webui)).

On the apiserver, usernames and groups get the `oidc:` prefix, and
`infra/rbac` binds `oidc:cluster-admins` to `cluster-admin`
([README.md, RBAC](README.md#rbac)). It is on: the `oidc` entry in
`cluster/definition.nix` sets the issuer
`https://auth.neuros.is/application/o/kubernetes/` and the audience
`kubernetes` on every control plane (`clusterNode.oidc`,
`modules/cluster/control-plane.nix`). To turn it off, remove that entry and
switch every control plane (c4130, r440, m2mini), one at a time. The
apiservers fetch the discovery document and JWKS through the public URL
(Cloudflare → the cluster's tunnel). If authentik or the tunnel is down,
OIDC logins fail and everything else keeps working. The apiserver starts
anyway, and its JWT authenticator retries in the background.

To log in, add yourself to `cluster-admins` in authentik, then on your
machine:

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

kubelogin serves its login page on `http://localhost:8000` (or `:18000` if
8000 is taken) on the machine running kubectl, which redirects to
auth.neuros.is. When kubectl runs over SSH, forward the port first:
`ssh -L 8000:localhost:8000 <host>`. Older kubectl without
`--exec-interactive-mode`: add `interactiveMode: IfAvailable` under the
user's `exec:` in the kubeconfig by hand.

## Headlamp

Kubernetes web UI (`components/apps/headlamp.nix`, Headlamp chart, image
`ghcr.io/headlamp-k8s/headlamp`), namespace `headlamp`. One replica, amd64
only (nodeSelector): with c4130 tainted for vLLM that means r440.

Public at **https://k8s.neuros.is** (`cluster.headlamp.host`) through the
cluster's tunnel, to Service `headlamp/headlamp` at its fixed ClusterIP
(`cluster.headlamp.serviceIP`, 10.96.0.21, port 80). No Ingress. ClusterIP
is immutable, so that Service carries Flux's force annotation (recreated,
not patched, if the IP changes).

**Login** is OIDC with authentik's confidential client `headlamp`, scopes
`openid profile email groups`, callback
`https://<cluster.headlamp.host>/oidc-callback`. Headlamp forwards each
user's own ID token to the apiserver. authentik's issuer is per provider
(`https://auth.neuros.is/application/o/headlamp/`), so that is a second JWT
authenticator on the apiserver (`oidc.extraIssuers` in
`cluster/definition.nix`, audience `headlamp`, same `oidc:` prefixes), not
just another audience. Changing it means switching every control plane.
Client id, issuer, scopes and callback are plain env values in the
component.

**RBAC:** the pod's own ServiceAccount has none: the chart's default
cluster-admin ClusterRoleBinding is disabled and
`unsafeUseServiceAccountToken` stays off (the token is still mounted:
in-cluster mode reads the apiserver address and CA from it). What a user
sees is what `oidc:cluster-admins` (or their other groups) allow.

**Pod security:** the namespace enforces `restricted` (the image runs as
uid 100; non-root, seccomp RuntimeDefault, all capabilities dropped, no
privilege escalation).

### The Secret (headlamp/headlamp-oidc)

Key `OIDC_CLIENT_SECRET`: the client secret authentik generated for the
provider `headlamp` (Applications → Providers → `headlamp`; generate
nothing here), sops-encrypted in
`k8s/secrets/headlamp/headlamp-oidc.sops.yaml`. If authentik's secret
changes, paste the new one into the file
([secrets.md, Changing a value](secrets.md#changing-a-value-rotation): the
`read -rs` line, key `OIDC_CLIENT_SECRET`), merge, then
`kubectl -n headlamp rollout restart deploy/headlamp`.

Until the Secret is applied the pod sits in `CreateContainerConfigError`;
nothing else breaks. Without the tunnel:
`kubectl -n headlamp port-forward svc/headlamp 4466:80` (the OIDC callback
still points at k8s.neuros.is, so log in there).

## Cloudflare tunnel

All public hostnames go through **one** locally managed tunnel, `cluster`
(`cluster.tunnel`, id `59a275ca-be31-4f8d-99ce-c536eaf490f8`), run in the
cluster by `components/apps/cloudflared/`, namespace `cloudflared`:

```
https://<host> -> Cloudflare edge -> cloudflared (any replica)
  -> nginx sidecar on 127.0.0.1:9190 (same pod)
  -> http://<service ClusterIP>:80 (cluster.<service>.serviceIP)
     or, for the Nix cache (cluster.binaryCache), r440's LAN address
```

| File | What |
| --- | --- |
| `files.nix` | routes (hostname → upstream) and both config files, built from `cluster/definition.nix` |
| `nginx.conf` | the nginx sidecar's config (template) |
| `configmap.nix` | both files as a ConfigMap |
| `deployment.nix` | one replica per node, hostNetwork, cloudflared + nginx |

| Hostname | Upstream |
| --- | --- |
| `auth.neuros.is` | authentik, ClusterIP 10.96.0.20 |
| `k8s.neuros.is` | Headlamp, ClusterIP 10.96.0.21 |
| `chat.neuros.is` | Open WebUI, ClusterIP 10.96.0.22 |
| `flux.neuros.is` | Flux Receiver, ClusterIP 10.96.0.23 (`/hook/` only) |
| `cache.neuros.is` | r440's Nix binary cache: nginx (basic auth) on r440's LAN address, `10.0.0.239:5080` (`cluster.binaryCache`; not a Service) |

The cache is the one route that leaves the cluster: nginx on r440
(`hosts/r440/cache.nix`) asks for the password and fronts harmonia; its
firewall opens 5080 to the nodes' LAN IPs, which is where these hostNetwork
pods connect from. Authorization headers pass through the sidecar
untouched; responses carry `Cache-Control: private, no-store`, so the edge
caches nothing. Setup and secrets: [../build-cache.md](../build-cache.md).

- **Replicas.** One per node (required anti-affinity; c4130's GPU taint is
  tolerated), so every node is a connector and the tunnel survives any one
  node being down.
- **Proxy.** Each pod runs with `hostNetwork` (the namespace is
  `privileged` for that reason only; the containers are unprivileged,
  read-only and without capabilities). cloudflared sends every hostname to
  the nginx sidecar on `127.0.0.1:9190`. Cloudflare *appends* the visitor's
  IP to a client-sent `X-Forwarded-For`, and authentik (and Open WebUI)
  read the leftmost entry, so nginx *replaces* `X-Forwarded-For` and
  `X-Real-IP` with Cloudflare's `Cf-Connecting-Ip`, which the edge always
  sets. nginx keeps the Host header; websockets pass through. Because of
  hostNetwork, nginx reaches the ClusterIPs from the node's cni0/flannel
  addresses (10.244.N.0/31), which is what authentik trusts.
- **Credential.** The Secret `cloudflared/tunnel-credentials`, key
  `credentials.json` (the JSON `cloudflared tunnel create cluster` wrote),
  sops-encrypted in `k8s/secrets/cloudflared/tunnel-credentials.sops.yaml`
  ([secrets.md](secrets.md)); read at start. To replace it (a new tunnel,
  or rotated credentials), on a machine with the JSON:

  ```sh
  base64 -w0 < <path to the JSON> | jq -R . \
    | sops set --value-stdin k8s/secrets/cloudflared/tunnel-credentials.sops.yaml '["data"]["credentials.json"]'
  ```

  then PR, merge, `kubectl -n cloudflared rollout restart deploy/cloudflared`
  (a new tunnel id also goes in `cluster.tunnel`).
- **DNS.** A proxied CNAME per hostname to `<tunnel id>.cfargotunnel.com`,
  made with the Cloudflare account cert (where it lives:
  [../secrets.md](../secrets.md); `~admin/.cloudflared/cert.pem` on c4130,
  run as admin):
  `cloudflared tunnel route dns --overwrite-dns 59a275ca-be31-4f8d-99ce-c536eaf490f8 <hostname>`.
- **New hostname.** Add it to `routes` in `components/apps/cloudflared/files.nix`
  (with its `host`/`serviceIP` in `cluster/definition.nix`; the pods roll
  on config change), then add its DNS route.

## Open WebUI

Chat front-end for c4130's vLLM (`components/apps/open-webui.nix`),
namespace `open-webui`, public at **https://chat.neuros.is**
(`cluster.openWebui.host`) through the cluster's tunnel to Service
`open-webui` at its fixed ClusterIP (`cluster.openWebui.serviceIP`,
10.96.0.22) → pod :8080.

- **Placement.** One replica (SQLite; strategy `Recreate`), data
  (`webui.db`, uploads) on r440 at `/var/lib/open-webui/data` (hostPath PV,
  `Retain`), so the pod runs on r440. Keep it off c4130 (vLLM + LMCache need
  its RAM).
- **Login.** The local login form, plus **Continue with authentik**: OIDC
  against authentik's confidential client `open-webui` (blueprint
  `apps/authentik/blueprints/open-webui.yaml`), which only members of the
  authentik group **`local-ai`** may use. New SSO users are created
  (`ENABLE_OAUTH_SIGNUP`) with the instance's default role (pending unless
  an admin changed it). An existing account with the same e-mail is linked
  (`OAUTH_MERGE_ACCOUNTS_BY_EMAIL`). Roles are never taken from authentik,
  so no login can demote or promote an existing admin. OAuth settings come
  from the environment, never the database
  (`ENABLE_OAUTH_PERSISTENT_CONFIG` is off by default).
- **Models.** vLLM's OpenAI API on c4130's LAN address (`10.0.0.95:8000`),
  so the model follows `services.vllm-sm70.activeModel`
  ([../hosts/c4130-vllm.md](../hosts/c4130-vllm.md)).
- **Secrets.** The Secret `open-webui/open-webui-secrets`, sops-encrypted
  in `k8s/secrets/open-webui/open-webui-secrets.sops.yaml`
  ([secrets.md](secrets.md): how to change a value), has
  `WEBUI_SECRET_KEY` (signs sessions; changing it logs everyone out) and
  `OAUTH_CLIENT_SECRET` (authentik's generated secret for `open-webui`,
  readable in the admin UI under Providers). Read at start: after a change,
  `kubectl -n open-webui rollout restart deploy/open-webui`.
