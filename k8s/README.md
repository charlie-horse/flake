# k8s/ — in-cluster resources (catenix)

Every object in the cluster that is not a NixOS service is declared here as
a [catenix](https://github.com/charlie-horse/catenix) module and rendered to
a tree of YAML files that CI publishes as a signed OCI artifact and Flux
applies ([Deployment](#deployment)).

| File | Contents |
| --- | --- |
| `default.nix` | the registry: `components` and `deferred` (component name → module), `kubeVersion`, `cluster` (from `../cluster/definition.nix`). `{ inputs, pkgs, lib }` → `manifests` (the rendered tree), `checkImages`, `components`; the flake output `k8s` (`parts/k8s.nix`) |
| `render.nix` | the render mechanics `default.nix` hands the registry to: evaluates each component (module arguments `cluster`, `kubeVersion`, `deferred`, `catenix`, `k8sLib`, `charts`, `pkgs`), lays out the tree (file names, `00-`/`01-` prefixes, the `deferred/` fence), builds `manifests` and `checkImages` |
| `charts.nix` | published Helm charts, pinned by version + NAR hash (`catenix.lib.fetchChart`) |
| `lib.nix` | helpers for the components (module argument `k8sLib`): `localVolume`, `nodeTolerations`, `fixedServiceIP` |
| `components/infra/` | cluster plumbing, one file per component (a directory when split by concern, e.g. `cert-manager/`) |
| `components/flux/` | Flux itself: `install.nix` (chart), `sync.nix` (OCIRepository + Kustomization `flux-system`), `stages.nix` (a Kustomization per deferred component), `receiver.nix` (push webhook) |
| `components/apps/` | applications; small ones are a file, larger ones a directory split by concern (e.g. `authentik/`: `chart.nix`, `postgres.nix`, `backup.nix`, `blueprints/*.yaml`) |
| (render) | `nix build .#k8s.manifests`: `<component>/<plural kind>.yaml`, namespaces and CRDs as `00-`/`01-` files; deferred components under `deferred/<component>/` ([Deferred components](#deferred-components)); rules in `render.nix`. Built by CI, never committed. |

Cluster values (pod/service CIDRs, DNS IP, domain, nodes and their `gpu`
flag) come from `../cluster/definition.nix`, the same file the NixOS
modules read.

To add a component, write its module under `components/` and register it
with one line in `components` in `default.nix` (or in `deferred.modules`,
[below](#deferred-components)); the name is its directory in the render.
`render.nix` names no component and needs no change.

## Components

| Component (`<component>/` in the render) | What | Source |
| --- | --- | --- |
| `infra/runtime-classes` | RuntimeClass `runc` (default handler) and `nvidia` (handler `nvidia`, nodeSelector `nvidia.com/gpu.present=true`); `crun` documented, off | hand-written |
| `infra/rbac` | ClusterRoleBinding `system:kube-apiserver:kubelet-api-admin` (User `system:kube-apiserver`, the apiserver's kubelet client cert → ClusterRole `system:kubelet-api-admin`; without it `kubectl logs/exec/port-forward` get 403 from the kubelets); ClusterRoleBinding `oidc:cluster-admins` → `cluster-admin` (authentik group, inert until apiserver OIDC is on) | hand-written (what NixOS's disabled addon manager would create) |
| `infra/local-storage` | StorageClass `local` (no provisioner, WaitForFirstConsumer): static hostPath PVs pinned to a node | hand-written |
| `infra/flannel` | flannel VXLAN DaemonSet, `Network` = `podCidr`, kube-subnet-mgr, `--public-ip=$(status.hostIP)` (the node's LAN IP); no CNI install init containers (the host ships the plugin + conflist) | flannel chart v0.28.10 |
| `infra/coredns` | CoreDNS, Service `kube-system/kube-dns` at `dnsServiceIP` (10.96.0.10), zone `clusterDomain` (cluster.local), 2 replicas | coredns chart 1.48.2 (CoreDNS 1.14.7) |
| `infra/nvidia-device-plugin` | NVIDIA device plugin on `nvidia.com/gpu.present=true` nodes, `runtimeClassName: nvidia`, `DEVICE_ID_STRATEGY=index` (matches the host's index-named CDI spec) | nvidia-device-plugin chart 0.20.1 |
| `infra/cert-manager` | cert-manager v1.21.3 (namespace `cert-manager`, enforce `restricted`): CRDs, controller and cainjector (1 replica each), webhook (2 replicas, PDB); r440 and m2mini ([cert-manager](#cert-manager)) | jetstack cert-manager chart v1.21.3 |
| `infra/cert-manager-issuers` (deferred: `deferred/infra/cert-manager-issuers/`) | the workload CA: CA ClusterIssuer **`cluster-ca`** over the hand-made Secret `cert-manager/cluster-ca` (workload intermediate under the YubiKey root, [docs/pki-migration-plan.md](../docs/pki-migration-plan.md)); applied by the Kustomization `cert-manager-issuers` | hand-written (`components/infra/cert-manager/issuers.nix`) |
| `flux` | Flux v2.9.5: CRDs, source/kustomize/helm/notification controllers; OCIRepository `flux-system-oci` (the signed GHCR artifact) + Kustomization `flux-system`, one Kustomization per deferred component (`cert-manager-issuers`); Receiver `ghcr` (push webhook) | fluxcd-community flux2 chart 2.19.1 |
| `apps/cloudflared` | the single Cloudflare tunnel `cluster`: cloudflared, one replica per node (hostNetwork), nginx sidecar that sets `X-Forwarded-For` from `Cf-Connecting-Ip`; routes auth/k8s/chat, the Flux webhook host (`/hook/` only) and `cache.neuros.is` (r440's Nix cache, outside the cluster) | hand-written |
| `apps/authentik` | authentik (SSO/OIDC): one server + one worker per node, PostgreSQL 17 StatefulSet on m2mini (hostPath PV), daily `pg_dump` CronJob to r440, blueprints (one file per OIDC client: `kubernetes`, `headlamp`, `open-webui`). Secrets come from a hand-made Secret ([below](#authentik)) | authentik chart 2026.8.5 + hand-written |
| `apps/headlamp` | Headlamp web UI (namespace `headlamp`, enforce `restricted`): 1 replica on amd64 (r440), Service `headlamp` at fixed ClusterIP 10.96.0.21, OIDC login via authentik's confidential client `headlamp`; its ServiceAccount has no RBAC (users act with their own token). Client secret from a hand-made Secret ([below](#headlamp)) | headlamp chart 0.46.0 |
| `apps/open-webui` | Open WebUI 0.12.2 (chat for c4130's vLLM at `10.0.0.95:8000`), one replica, data on r440 (hostPath PV), OIDC login via authentik for group `local-ai`; secrets from the hand-made Secret `open-webui/open-webui-secrets` ([below](#open-webui)) | hand-written |

Every image is a multi-arch manifest list (linux/amd64 + linux/arm64);
`nix build .#k8s.checkImages && ./result/bin/k8s-check-images` checks
it (CI runs it on every render, advisory). The device plugin is pinned to the
gpu node by its nodeSelector (its image happens to be multi-arch too).

## Flake output (parts/k8s.nix)

The render is the system-independent flake output `k8s`, built with the
nodes' 26.05 nixpkgs on x86_64-linux (YAML is the same for every system):

```sh
nix build .#k8s.manifests                                  # -> ./result
nix build .#k8s.checkImages && ./result/bin/k8s-check-images
nix eval .#k8s.components.\"apps/authentik\".config.build.manifests --json
```

It is deliberately **not** under `packages.<system>`: rendering is
import-from-derivation (catenix runs `helm template` in a derivation and
reads the result back), and `nix flake check` should not build it. The NixOS
configurations never touch `k8s/`. `inputs.catenix` follows the flake's
`nixpkgs`.

## Deployment

`.github/workflows/render.yml`, on every push to `main` that touches a render
input (`k8s/`, `cluster/`, `parts/`, `flake.*`):

1. `nix build .#k8s.manifests` from that commit, fail on key material, check
   the images (advisory);
2. `flux push artifact` to `oci://ghcr.io/charlie-horse/flake/manifests`
   (tags `<sha12>` and `main`), `cosign sign` (keyless, the workflow's
   GitHub OIDC identity);
3. POST to Flux's Receiver, so the cluster fetches it at once.

Flux (`components/flux/sync.nix`) applies only artifacts signed by
`render.yml` on `main`. Pull requests get step 1 only. Every push to `main`
publishes (a revert included); dispatching `render.yml` on `main`
republishes. Nothing reaches the cluster before it is merged.

Validation: catenix type-checks every object against the Kubernetes v1.37
OpenAPI spec and the charts' CRDs at evaluation time (`validation.strict`).

### Deferred components

The Kustomization `flux-system` applies the whole tree in one go, and Flux
server-side dry-runs **every** object before applying **any**: one rejected
object fails the whole apply. Objects guarded by an admission webhook with
`failurePolicy: Fail` (cert-manager's checks every `cert-manager.io` object,
dry runs included) would therefore tie the whole cluster's deployment to
that webhook: with it down, nothing would be applied, including a fix for
the webhook itself.

Such objects go in a *deferred* component (`deferred.modules` in
`default.nix`; `render.nix` places it and writes the fence):

- it renders under `deferred/<component>/`; `deferred/kustomization.yaml`
  lists no resources, and Flux's generator takes a directory holding a
  `kustomization.yaml` as a base without looking inside, so `flux-system`
  (path `./`) skips the subtree;
- `components/flux/stages.nix` gives it its own Kustomization (named after
  the component's last path element), from the same artifact, with
  `dependsOn: flux-system` (it runs once `flux-system` has applied the same
  revision: CRDs, the webhook Deployment), `retryInterval: 1m` (until the
  webhook answers) and `wait: true` (Ready only when its objects are).

A failure there stays there: `flux-system` keeps applying the rest.
Today the only one is `infra/cert-manager-issuers`.

## Bootstrap (fresh cluster, operator with an admin kubeconfig)

Flux can't run before the pod network and DNS do, so the first apply is
manual; afterwards Flux owns everything in the render, itself included.

```sh
nix build .#k8s.manifests && R=./result
kubectl apply --server-side -R -f $R/infra/
kubectl apply --server-side -f $R/flux/00-namespaces.yaml -f $R/flux/01-customresourcedefinitions.yaml
kubectl wait --for condition=established --timeout=60s \
  crd/ocirepositories.source.toolkit.fluxcd.io \
  crd/kustomizations.kustomize.toolkit.fluxcd.io \
  crd/receivers.notification.toolkit.fluxcd.io
kubectl apply --server-side -R -f $R/flux/
flux get kustomizations --watch   # or: kubectl -n flux-system get ks
```

In every component, `00-namespaces.yaml` and
`01-customresourcedefinitions.yaml` sort first, so `kubectl apply -R`
creates them before the objects that need them. Flux's custom resources
also need their CRDs *established*, hence the separate step and the wait.
The apps and `deferred/` need no manual apply: Flux brings them up (never
`kubectl apply -R -f $R` on the whole tree: `deferred/kustomization.yaml`
is not a Kubernetes object).

Smoke test: `flux get kustomizations` shows `flux-system` and
`cert-manager-issuers` Ready, `kubectl get clusterissuers` shows
`cluster-ca` Ready (both need the hand-made Secret
`cert-manager/cluster-ca`, [cert-manager](#cert-manager)), and `kubectl get pods -A -o wide` shows one cloudflared
and one authentik server per node.

## Host-side assumptions (modules/cluster)

- containerd runtime handlers `runc` (default) and `nvidia` (gpu nodes);
  `crun` only with `clusterNode.crun.enable` (then flip `enableCrun` in
  `components/infra/runtime-classes.nix` and label those nodes).
- gpu nodes carry the label `nvidia.com/gpu.present=true`.
- kubelet `--node-ip` = `lanIP` (so `status.hostIP` is the LAN address
  flannel uses), `clusterDNS` = `dnsServiceIP`, `clusterDomain`.
- `/opt/cni/bin` has the `flannel` and `portmap` plugins and
  `/etc/cni/net.d/10-flannel.conflist` is provided by NixOS.
- kube-controller-manager allocates node CIDRs (`--allocate-node-cidrs`,
  `--cluster-cidr` = `podCidr`, mask `nodeCidrMaskSize`).
- udp/8472 open between the nodes' LAN IPs (VXLAN). To run VXLAN over
  Tailscale instead, set `transport = "tailscale"` in
  `components/infra/flannel.nix`.
- kube-proxy runs on every node with `--cluster-cidr` = `podCidr`, so the
  apiservers (host network) reach webhook Services by ClusterIP, masqueraded
  to the node's flannel address; no extra firewall rule (see
  [cert-manager](#cert-manager)).

## cert-manager

The workload PKI (`components/infra/cert-manager/`): TLS for things that run
**in** the cluster. The cluster's own certificates (etcd, apiservers,
kubelets, …) are not cert-manager's: they are files from `cluster-pki`, made
before the cluster exists ([docs/pki.md](../docs/pki.md#bootstrap-pki-and-workload-pki)).

| Object | What |
| --- | --- |
| Secret `cert-manager/cluster-ca` | the workload intermediate CA (ECDSA P-384, 2 y), signed by the YubiKey root: `tls.crt` = intermediate + root, `tls.key`, `ca.crt` = root. **Created by hand** at the ceremony, never in git, never copied out ([docs/pki-migration-plan.md](../docs/pki-migration-plan.md)) |
| ClusterIssuer **`cluster-ca`** | CA issuer over that Secret: **what workloads use** |

Only the ClusterIssuer is declared. No Kustomization owns the Secret, so
Flux neither prunes nor overwrites it, and no Certificate points at it, so
cert-manager does not renew it: renewal is manual, before the
intermediate's 2-year expiry. Without the Secret the ClusterIssuer (and the
Kustomization `cert-manager-issuers`) is NotReady and nothing else breaks.
A backup of the etcd data holds the key, like every Secret.

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
`catenix.crdModule` over the chart's CRDs), and the component must be
**deferred** ([Deferred components](#deferred-components)), as everything
`cert-manager.io` is. Defaults: 90 days, renewed at 2/3; keep durations
under the intermediate's remaining life. Clients that should trust these
certificates use `ca.crt` from any issued Secret, or the root,
`cluster/pki/root-ca.pem` (public, in git).

cert-manager approves every CertificateRequest for its own issuers, so
whoever may create a Certificate may get any name signed by `cluster-ca`.
Today that is only cluster admins and Flux; per-namespace policy would be
cert-manager's approver-policy. Nothing outside the cluster trusts
`cluster-ca`: it is for in-cluster TLS, not public hostnames (those go
through the Cloudflare tunnel).

### Webhook and network

The apiserver calls the webhook (`cert-manager/cert-manager-webhook`, port
443 → pod 10250) through its ClusterIP, with no aggregator routing.
kube-proxy on the apiserver's node DNATs it to a webhook pod and, the source
being outside `podCidr`, masquerades it to that node's flannel address;
VXLAN carries it to the pod's node (udp/8472 between LAN IPs, open on every
node by `modules/cluster/firewall.nix`, c4130 included, whatever
`trustTailscale`), and the reply returns on the same connection. The
NixOS firewall filters only INPUT, not forwarded pod traffic. Checked
2026-11-12: every apiserver (c4130, r440, m2mini) reaches pods on all three
nodes through the apiserver proxy. The webhook's own serving cert is
self-managed (Secret `cert-manager-webhook-ca`, injected into the webhook
configurations by the cainjector), so it does not depend on `cluster-ca`.

### Removing it

Deleting the ClusterIssuer, or the whole component, leaves the Secret
`cluster-ca`. Deleting the Secret loses the intermediate's key: a new one
has to be signed by the root (docs/pki-migration-plan.md). Removing
`infra/cert-manager` removes its CRDs and with them every Certificate and
Issuer in the cluster.

## authentik

SSO for the cluster and its apps (`components/apps/authentik/`). It runs
**in** the cluster but the cluster never depends on it: kubelets, the
control plane and the admin kubeconfig authenticate with x509 certs, Flux
and pods with service-account tokens. OIDC is only an extra way for people
to log in. If authentik is down, only those logins fail; the admin cert
(`r440:~/.local/share/cluster-pki/neurosis/admin.kubeconfig`) is the
break-glass.

| Piece | Where | Data |
| --- | --- | --- |
| `authentik-server`, `authentik-worker` | amd64 nodes (r440; c4130 is tainted) | none |
| `authentik-postgresql` (StatefulSet, postgres 17.11) | m2mini (PV node affinity) | `m2mini:/var/lib/authentik/postgres` |
| `authentik-backup` (CronJob 03:17 America/New_York) | r440 (PV node affinity) | `r440:/var/lib/authentik/backup/authentik-*.dump` (`pg_dump -Fc`, newest 14) |

The PVs are hostPath (`DirectoryOrCreate`, reclaim `Retain`): deleting the
claim or the component never deletes data. Postgres sits on m2mini's NVMe
rather than r440, whose root is the 5400 rpm HDD that already slows its etcd
WAL.

### The Secret (once, by hand, never in git)

The pods read `authentik/authentik-secrets`. Flux doesn't create or prune it.
Until it exists, the pods sit in `CreateContainerConfigError` (they start
by themselves once it does) and nothing else is affected. Create it on r440
with the operator kubeconfig. The values are generated in place and never
appear on a command line:

```sh
export KUBECONFIG=~/.local/share/cluster-pki/neurosis/admin.kubeconfig
nix shell nixpkgs#kubectl nixpkgs#openssl -c bash -ec '
  umask 077
  {
    echo "AUTHENTIK_SECRET_KEY=$(openssl rand -base64 60 | tr -d "\n")"
    echo "AUTHENTIK_POSTGRESQL__PASSWORD=$(openssl rand -hex 32)"
    echo "AUTHENTIK_BOOTSTRAP_PASSWORD=$(openssl rand -base64 24 | tr -d "\n/+=")"
  } | kubectl -n authentik create secret generic authentik-secrets \
        --from-env-file=/dev/stdin'
```

- `AUTHENTIK_SECRET_KEY` signs sessions and encrypts stored secrets. Never
  change it once authentik has started.
- `AUTHENTIK_POSTGRESQL__PASSWORD` is also the database's
  `POSTGRES_PASSWORD`. That variable only takes effect on the first start
  with an empty data dir. Afterwards, change it with `ALTER ROLE` first.
- `AUTHENTIK_BOOTSTRAP_PASSWORD` is `akadmin`'s password, set on the first
  start only. Read it with
  `kubectl -n authentik get secret authentik-secrets -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_PASSWORD}' | base64 -d`,
  then change it in the UI.

### Reaching it

Public: **https://auth.neuros.is** (`cluster.authentik.host`), through the
cluster's single Cloudflare tunnel (see [Cloudflare tunnel](#cloudflare-tunnel)),
to Service `authentik-server` at its fixed ClusterIP
(`cluster.authentik.serviceIP`, 10.96.0.20, in the static band of the
service CIDR). authentik trusts `X-Forwarded-*` only from the tunnel's
proxies, i.e. the nodes' own addresses (`AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS`).

The admin UI is public too: give `akadmin` a strong password plus MFA, and
add real users rather than sharing it. Without the tunnel:

```sh
kubectl -n authentik port-forward svc/authentik-server 9000:80
```

### Cluster login (kube-apiserver OIDC)

The blueprint (ConfigMap `authentik-blueprints`, applied by the worker)
creates:

- the group `cluster-admins`;
- the public OAuth2/OIDC provider `kubernetes` (client id `kubernetes`,
  PKCE, RS256 with authentik's self-signed key, redirect
  `http://localhost:8000` and `:18000` for kubelogin);
- the application `kubernetes`, which only `cluster-admins` may use;
- the confidential provider and application `headlamp` (client id
  `headlamp`, redirect `https://k8s.neuros.is/oidc-callback`), also
  `cluster-admins` only. See [Headlamp](#headlamp).

On the apiserver, usernames and groups get the `oidc:` prefix, and
`infra/rbac` binds `oidc:cluster-admins` to `cluster-admin`. It is on: the
`oidc` entry in `cluster/definition.nix` sets the issuer
`https://auth.neuros.is/application/o/kubernetes/` and the audience
`kubernetes` on every control plane (`clusterNode.oidc`). To turn it off,
remove that entry and switch r440 and c4130. The apiservers fetch the
discovery document and JWKS through the public URL (Cloudflare → r440 tunnel).
If authentik or the tunnel is down, OIDC logins fail and everything else
keeps working. The apiserver starts anyway, and its JWT authenticator retries
in the background.

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

Kubernetes web UI (`components/apps/headlamp.nix`), public at
**https://k8s.neuros.is** (`cluster.headlamp.host`) through the cluster's
Cloudflare tunnel (see [Cloudflare tunnel](#cloudflare-tunnel)), to Service
`headlamp/headlamp` at its fixed ClusterIP (`cluster.headlamp.serviceIP`,
10.96.0.21).

Login is OIDC with authentik's confidential client `headlamp`. Headlamp
forwards the user's ID token to the apiserver. authentik's issuer is per
provider (`https://auth.neuros.is/application/o/headlamp/`), so that is a
second JWT authenticator on the apiserver (`oidc.extraIssuers` in
`cluster/definition.nix`, audience `headlamp`, same `oidc:` prefixes), not
just another audience. Changing it means switching r440 and c4130. The pod's
own ServiceAccount has no RBAC; what a user sees is what
`oidc:cluster-admins` (or their other groups) allow.

### The Secret (once, by hand, never in git)

Copy the client secret from authentik (Applications → Providers →
`headlamp`), then on r440 with the operator kubeconfig paste it on stdin:

```sh
export KUBECONFIG=~/.local/share/cluster-pki/neurosis/admin.kubeconfig
nix shell nixpkgs#kubectl -c kubectl -n headlamp create secret generic \
  headlamp-oidc --from-env-file=/dev/stdin
# type: OIDC_CLIENT_SECRET=<secret>   then Enter, Ctrl-D
```

Until it exists the pod sits in `CreateContainerConfigError`. Without the
tunnel: `kubectl -n headlamp port-forward svc/headlamp 4466:80` (the OIDC
callback still points at k8s.neuros.is, so log in there).

## Cloudflare tunnel

All public hostnames go through **one** locally managed tunnel, `cluster`
(`cluster.tunnel`, id `59a275ca-be31-4f8d-99ce-c536eaf490f8`), run in the
cluster by `components/apps/cloudflared/`:

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
caches nothing. Setup and secrets: docs/cluster.md, "Binary cache".

- **Replicas.** One per node (required anti-affinity; c4130's GPU taint is
  tolerated), so every node is a connector and the tunnel survives any one
  node being down.
- **Proxy.** Each pod runs with `hostNetwork` (the namespace is
  `privileged` for that reason only; the containers are unprivileged and
  read-only). cloudflared sends every hostname to an nginx sidecar on
  `127.0.0.1:9190`. nginx *replaces* `X-Forwarded-For` and `X-Real-IP` with
  Cloudflare's `Cf-Connecting-Ip`, which the edge always sets. Cloudflare
  itself appends to a client-sent `X-Forwarded-For`, and authentik reads the
  leftmost entry. Because of hostNetwork, nginx reaches the ClusterIPs from
  the node's cni0/flannel addresses (10.244.N.0/31), which is what authentik
  trusts.
- **Credential.** The Secret `cloudflared/tunnel-credentials` (key
  `credentials.json`), made once by hand, never in git:

  ```sh
  # on a machine with the JSON from `cloudflared tunnel create cluster`:
  kubectl -n cloudflared create secret generic tunnel-credentials \
    --from-file=credentials.json=<path to the JSON>
  ```

- **DNS.** A proxied CNAME per hostname to the tunnel (account cert:
  charlie's `~/.cloudflared/cert.pem` on c4130):
  `cloudflared tunnel route dns --overwrite-dns 59a275ca-be31-4f8d-99ce-c536eaf490f8 <hostname>`.
- **New hostname.** Add it to `routes` in `components/apps/cloudflared/` (the
  pods roll on config change), then add its DNS route.

## Open WebUI

Chat front-end for c4130's vLLM (`components/apps/open-webui.nix`), public at
**https://chat.neuros.is** through the cluster's tunnel. It moved here from
a NixOS service on c4130 on 2026-11-10, at the same version (0.12.2), with
its data (`webui.db`, uploads) copied to `r440:/var/lib/open-webui/data` (a
hostPath PV, Retain).

- **Login.** The local login form works as before, plus **Continue with
  authentik**: OIDC against authentik's confidential client `open-webui`,
  which only members of the authentik group **`local-ai`** may use. New SSO
  users are created with the instance's default role (pending unless an
  admin changed it). An existing account with the same e-mail is linked
  to its SSO login. Roles are never taken from authentik.
- **Models.** vLLM's OpenAI API on c4130's LAN address (`10.0.0.95:8000`),
  so the model follows `services.vllm-sm70.activeModel` as before.
- **Secrets.** Never in git. The Secret `open-webui/open-webui-secrets` has
  `WEBUI_SECRET_KEY` (signs sessions; carried over from c4130's
  `.webui_secret_key`) and `OAUTH_CLIENT_SECRET` (authentik's generated
  secret for `open-webui`, readable in the admin UI under Providers).

