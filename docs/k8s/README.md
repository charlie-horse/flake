# Kubernetes: in-cluster resources (`k8s/`)

Every object in the cluster that is not a NixOS service is declared in
[`k8s/`](../../k8s) as a [catenix](https://github.com/charlie-horse/catenix)
module. It is rendered to a tree of YAML files, which CI publishes as a
signed OCI artifact and Flux applies ([Deployment](#deployment)).

Related docs: [secrets.md](secrets.md) (the sops-encrypted Secrets),
[apps.md](apps.md) (cert-manager, authentik, Headlamp, the Cloudflare
tunnel, Open WebUI), [../pki.md](../pki.md) (the cluster PKI and the
`cluster-pki` namespace), [../ci.md](../ci.md#renderyml) (`render.yml`),
[../cluster.md](../cluster.md) (hosts, access, the cluster runbook).

## Layout

| File | Contents |
| --- | --- |
| `default.nix` | the registry: `components` and `deferred` (component name → module), `kubeVersion`, `cluster` (from `../cluster/definition.nix`). `{ inputs, pkgs, lib }` → `manifests`, `checkImages`, `components` ([Flake output](#flake-output-partsk8snix)) |
| `render.nix` | the render mechanics `default.nix` hands the registry to: evaluates each component, lays out the tree, builds `manifests` and `checkImages` ([The render](#the-render-rendernix)). It names no component |
| `charts.nix` | published Helm charts, pinned by version + NAR hash (`catenix.lib.fetchChart`) |
| `lib.nix` | helpers for the components (module argument `k8sLib`): `localVolume`, `nodeTolerations`, `fixedServiceIP` |
| `components/infra/` | cluster plumbing, one file per component (a directory when split by concern, e.g. `cert-manager/`, `cluster-pki/`) |
| `components/flux/` | Flux itself: `install.nix` (chart), `sync.nix` (OCIRepository + Kustomization `flux-system`), `stages.nix` (a Kustomization per deferred component), `secrets.nix` (Kustomization `secrets`), `receiver.nix` (push webhook) |
| `components/apps/` | applications; small ones are a file, larger ones a directory split by concern (e.g. `authentik/`: `chart.nix`, `postgres.nix`, `backup.nix`, `blueprints/*.yaml`) |
| `secrets/` | sops-encrypted Secrets, `<namespace>/<name>.sops.yaml`, copied verbatim into the render ([secrets.md](secrets.md)) |

Cluster values (pod/service CIDRs, DNS IP, domain, nodes and their `gpu`
flag, public hostnames and fixed ClusterIPs) come from
`cluster/definition.nix`, the same file the NixOS modules read.

**Adding a component:** write its module under `components/` and register
it with one line in `components` in `default.nix` (or in
`deferred.modules`, [below](#deferred-components)); the name is its
directory in the render. `render.nix` needs no change.

## Components

| Component (`<component>/` in the render) | What | Source |
| --- | --- | --- |
| `infra/runtime-classes` | RuntimeClass `runc` and `nvidia` ([Runtime classes](#runtime-classes)) | hand-written |
| `infra/rbac` | ClusterRoleBindings `system:kube-apiserver:kubelet-api-admin` and `oidc:cluster-admins` ([RBAC](#rbac)) | hand-written |
| `infra/local-storage` | StorageClass `local` (no provisioner, WaitForFirstConsumer): static hostPath PVs pinned to a node (`k8sLib.localVolume`, reclaim `Retain`) | hand-written |
| `infra/flannel` | flannel VXLAN DaemonSet ([flannel](#flannel)) | flannel chart v0.28.10 |
| `infra/coredns` | CoreDNS, Service `kube-system/kube-dns` at `dnsServiceIP` (10.96.0.10), zone `clusterDomain` (cluster.local), 2 replicas | coredns chart 1.48.2 (CoreDNS 1.14.7) |
| `infra/nvidia-device-plugin` | NVIDIA device plugin on `nvidia.com/gpu.present=true` nodes, `runtimeClassName: nvidia`, `DEVICE_ID_STRATEGY=index` (matches the host's index-named CDI spec) | nvidia-device-plugin chart 0.20.1 |
| `infra/cert-manager` | cert-manager v1.21.3 (namespace `cert-manager`, enforce `restricted`): CRDs, controller and cainjector (1 replica each), webhook (2 replicas, PDB; r440 and m2mini); built-in auto-approver off, **approver-policy** v0.29.0 approves requests instead ([apps.md, cert-manager](apps.md#cert-manager)) | jetstack cert-manager chart v1.21.3, cert-manager-approver-policy chart v0.29.0 |
| `infra/cert-manager-issuers` (deferred) | the workload CA: ClusterIssuer **`cluster-ca`** over the Secret `cert-manager/cluster-ca`, its CertificateRequestPolicy `cluster-ca` (allow all but CA certs) and the `use` grant for cert-manager's controller ([apps.md, cert-manager](apps.md#cert-manager)) | hand-written (`components/infra/cert-manager/issuers.nix`) |
| `infra/cluster-pki` | namespace `cluster-pki` (enforce `restricted`) with the bootstrap CAs' Secrets and the export CronJob `pki-export` ([../pki.md, In-cluster issuance](../pki.md#in-cluster-issuance)) | hand-written (`components/infra/cluster-pki/default.nix`, `export.nix`) |
| `infra/cluster-pki-issuers` (deferred) | CA Issuers `k8s-ca`, `etcd-ca`, `front-proxy-ca`; one Certificate per host leaf per node (`leaves.nix`, from `cluster/definition.nix`), one CertificateRequestPolicy per leaf, the `use` grant ([../pki.md](../pki.md#in-cluster-issuance)) | hand-written (`components/infra/cluster-pki/issuers.nix`) |
| `flux` | Flux v2.9.5: CRDs, source/kustomize/helm/notification controllers; OCIRepository `flux-system-oci` + Kustomization `flux-system`, one Kustomization per deferred component, Kustomization `secrets`; Receiver `ghcr` ([Deployment](#deployment)) | fluxcd-community flux2 chart 2.19.1 |
| `apps/cloudflared` | the single Cloudflare tunnel `cluster`, one replica per node ([apps.md](apps.md#cloudflare-tunnel)) | hand-written |
| `apps/authentik` | authentik (SSO/OIDC): one server + one worker per node, PostgreSQL 17 on m2mini, daily backup to r440, blueprints ([apps.md](apps.md#authentik)) | authentik chart 2026.8.5 + hand-written |
| `apps/headlamp` | Headlamp web UI, 1 replica on r440 ([apps.md](apps.md#headlamp)) | headlamp chart 0.46.0 |
| `apps/open-webui` | Open WebUI 0.12.2, chat for c4130's vLLM, data on r440 ([apps.md](apps.md#open-webui)) | hand-written |

Every image is a multi-arch manifest list (linux/amd64 + linux/arm64);
`nix build .#k8s.checkImages && ./result/bin/k8s-check-images` checks it
(CI runs it on every render, advisory). Exempt (pinned to amd64 nodes):
the NVIDIA device plugin and `pki-export`.

### Runtime classes

`components/infra/runtime-classes.nix` matches the containerd runtime
handlers that `modules/cluster/node.nix` configures:

- `runc`: every node, containerd's default handler (also used by pods
  without a `runtimeClassName`).
- `nvidia`: gpu nodes only (`cluster.nodes.<n>.gpu = true`): runc wrapped
  by nvidia-container-runtime in CDI mode. Its scheduling nodeSelector keeps
  such pods on nodes labelled `nvidia.com/gpu.present=true` (node.nix sets
  that label from `gpu`).
- `crun`: optional, off (`enableCrun`). Turn it on only together with
  `clusterNode.crun.enable = true` on the nodes that should run it, and
  give those nodes a label (e.g.
  `cluster.nodes.<n>.labels."runtime.neurosis/crun" = "true"`) that
  `crunNodeSelector` names.

### RBAC

`components/infra/rbac.nix` (the NixOS addon manager is disabled in
`modules/cluster/default.nix`):

- `system:kube-apiserver:kubelet-api-admin`: the apiserver's kubelet client
  cert (`apiserver-kubelet-client-<n>`, `CN=system:kube-apiserver`, no O)
  must be allowed by the kubelets' Webhook authorizer, or
  `kubectl logs/exec/attach/port-forward`, `top` and node proxying get 403.
- `oidc:cluster-admins` → `cluster-admin`: members of the authentik group
  `cluster-admins` (blueprint `apps/authentik/blueprints/kubernetes-oidc.yaml`)
  when they log in with OIDC. The apiserver prefixes OIDC groups with
  `oidc:` (`modules/cluster/control-plane.nix`). OIDC is on (the `oidc`
  entry in `cluster/definition.nix`); without it the binding is inert.

Bootstrap applies this component with the admin cert together with the
network and DNS ([Bootstrap](#bootstrap-fresh-cluster)); Flux keeps it
afterwards.

### flannel

`components/infra/flannel.nix`: the pod network (`cluster.podCidr`),
VXLAN, kube-subnet-mgr mode (each node's `spec.podCIDR`, allocated by
kube-controller-manager from `--cluster-cidr` = `podCidr` with
`nodeCidrMaskSize`, is that node's subnet).

The host side is NixOS (`modules/cluster/node.nix`): the `flannel` and
`portmap` CNI plugins in `/opt/cni/bin` and the read-only
`10-flannel.conflist` in `/etc/cni/net.d`. The chart's install-cni init
containers (and their hostPath volumes) are dropped; the DaemonSet only
runs flanneld, which writes `/run/flannel/subnet.env` for the plugin.

`transport` picks what VXLAN runs over:

- `"lan"` (default): `--public-ip` = the node's InternalIP
  (`status.hostIP` = `cluster.nodes.<n>.lanIP`, the kubelet's `--node-ip`).
  flanneld uses the interface holding that address (`eno1` on c4130/r440,
  `end0` on m2mini), never the keepalived VIP, `bond0` or `tailscale0`.
  The firewall opens
  udp/8472 from the nodes' LAN IPs (`modules/cluster/firewall.nix`).
- `"tailscale"`: `--iface=tailscale0`, VXLAN over the tailnet (trusted
  interface, so no firewall change), MTU from tailscale0 (1280 − 50).
  Slower; for nodes that don't share a LAN.

## Flake output (parts/k8s.nix)

The render is the system-independent flake output `k8s`, built with the
nodes' 26.05 nixpkgs on x86_64-linux (YAML is the same for every system):

```sh
nix build .#k8s.manifests                                  # -> ./result
nix build .#k8s.checkImages && ./result/bin/k8s-check-images
nix eval .#k8s.components.\"apps/authentik\".config.build.manifests --json
```

| Attribute | What |
| --- | --- |
| `manifests` | the rendered tree ([The render](#the-render-rendernix)) |
| `checkImages` | a script: every image in the tree must be a manifest list with linux/amd64 and linux/arm64 (network; not sandboxed) |
| `components` | the evaluated catenix configurations (for `nix eval`) |

Keep it out of `packages.<system>`: rendering is import-from-derivation
(catenix runs `helm template` in a derivation), and `nix flake check` must
not build it. The NixOS configurations never touch `k8s/`.
`inputs.catenix` follows the flake's `nixpkgs`.

Validation: catenix type-checks every object against its pinned Kubernetes
v1.37 OpenAPI spec and the imported charts' CRDs at evaluation time
(`validation.strict`). The charts are rendered with `helm template
--kube-version` = `kubeVersion` in `default.nix` (v1.36.3, the nodes'
`kubernetes` package).

Rendering on r440 needs a workaround for `catenix/kubernetes-src`:
[../cluster.md, Changing something in the cluster](../cluster.md#changing-something-in-the-cluster).

## The render (render.nix)

- **Files:** one per kind and component, `<component>/<plural kind>.yaml`
  (lower-case plural as kubectl names resources: `deployments`,
  `networkpolicies`, `ingresses`; never the singular, or Flux's
  Kustomization kind would collide with `kustomization.yaml`). Each file
  starts with a "Generated … do not edit" header.
- **Order:** namespaces and CRDs get a `00-`/`01-` prefix, so
  `kubectl apply -R` (which walks files alphabetically) creates them first.
- **Module arguments** of every component: `cluster`, `kubeVersion`,
  `deferred` (`{ dir, components, secrets }`), `catenix` (its lib),
  `k8sLib` (`lib.nix`), `charts` (`charts.nix`), `pkgs`.
- **Deferred components** render under `deferred/<component>/`, next to
  the fence `deferred/kustomization.yaml` ([below](#deferred-components)).
- **Secrets:** each `k8s/secrets/<namespace>/<name>.sops.yaml` is checked
  and copied byte for byte to `deferred/secrets/<namespace>/<name>.sops.yaml`
  ([secrets.md, Render](secrets.md#how-they-are-rendered-and-applied)).
- **Asserts:** a component is not both in `components` and `deferred`; no
  component is named `deferred[/…]`; deferred components have distinct
  last path elements (their Kustomization names) and none is named after
  the `secrets` Kustomization.

Built by CI, never committed.

## Deployment

`.github/workflows/render.yml` ([../ci.md, render.yml](../ci.md#renderyml)
is canonical for the workflow) runs on every push to `main` that touches a
render input:

1. `nix build .#k8s.manifests` from that commit, fail on key material,
   check the images (advisory);
2. `flux push artifact` to `oci://ghcr.io/charlie-horse/flake/manifests`
   (tags `<sha12>` and `main`), `cosign sign` (keyless, the workflow's
   GitHub OIDC identity);
3. POST to Flux's Receiver, so the cluster fetches it at once.

Pull requests get step 1 only. Nothing reaches the cluster before it is
merged.

On the cluster side (`components/flux/`):

- **`sync.nix`:** OCIRepository `flux-system-oci` (tag `main`, polled every
  24 h) verifies the cosign signature and accepts only the identity
  `…/.github/workflows/render.yml@refs/heads/main`. The Kustomization
  `flux-system` (path `./`) applies the whole tree but `deferred/`, every
  10 minutes (which also corrects drift), `prune: true`. Flux applies
  itself too, so it keeps itself up to date.
- **`receiver.nix`:** Receiver `ghcr` (`generic-hmac`, Secret
  `flux-system/webhook-token`) triggers the OCIRepository; reached through
  the tunnel at `https://flux.neuros.is/hook/<path>` (cloudflared passes only
  `/hook/` for that host). Changing the token also means updating the GitHub
  secrets `FLUX_WEBHOOK_TOKEN` and `FLUX_WEBHOOK_URL`
  ([../ci.md](../ci.md#renderyml), [secrets.md](secrets.md)).
- **`install.nix`:** the flux2 chart; image-automation/-reflector
  controllers off (nothing writes to git from the cluster), no Helm hooks
  (Flux is applied by kubectl, then by itself). `TUF_ROOT=/tmp/.sigstore`
  for source-controller (keyless cosign needs a writable TUF cache). The
  webhook-receiver Service
  sits at the fixed ClusterIP `cluster.fluxWebhook.serviceIP` (10.96.0.23).

Check or force a deploy: [../cluster.md, Changing something in the
cluster](../cluster.md#changing-something-in-the-cluster).

### Deferred components

Flux dry-runs every object of a Kustomization before applying any, so one
rejected object fails the whole apply. Put objects guarded by an admission
webhook with `failurePolicy: Fail` (everything `cert-manager.io`) in a
*deferred* component (`deferred.modules` in `default.nix`; `render.nix`
places it and writes the fence):

- it renders under `deferred/<component>/`; `deferred/kustomization.yaml`
  lists no resources, and Flux's generator takes a directory holding a
  `kustomization.yaml` as a base without looking inside, so `flux-system`
  (path `./`) skips the subtree;
- `components/flux/stages.nix` gives it its own Kustomization (named after
  the component's last path element, e.g. `cert-manager-issuers`), from the
  same artifact, with `dependsOn: flux-system` (it runs once `flux-system`
  has applied the same revision: CRDs, the webhook Deployment),
  `retryInterval: 1m` (until the webhook answers) and `wait: true` (Ready
  only when its objects are), `prune: true`, `interval: 10m`.

A failure there stays there: `flux-system` keeps applying the rest.
Deferred components: `infra/cert-manager-issuers` and
`infra/cluster-pki-issuers`. The encrypted
Secrets use the same fence (Kustomization `secrets`,
[secrets.md](secrets.md#how-they-are-rendered-and-applied)).

## Bootstrap (fresh cluster)

Flux can't run before the pod network and DNS do, so the first apply is
manual; afterwards Flux owns everything in the render, itself included. The
admin kubeconfig is the break-glass one on any node
(`/etc/kubernetes/admin.kubeconfig`, root only;
[../pki.md, Break-glass](../pki.md#break-glass)): build as admin, run
`kubectl` and `flux` as root.

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
also need their CRDs *established* (the separate step and the wait).
Then create `flux-system/sops-age`
([secrets.md, The bootstrap key](secrets.md#the-bootstrap-key-flux-systemsops-age))
so the Kustomization `secrets` can decrypt. The apps and `deferred/` need
no manual apply: Flux brings them up. Never `kubectl apply -R -f $R` on the
whole tree: `deferred/kustomization.yaml` is not a Kubernetes object.

Smoke test: `flux get kustomizations` shows `flux-system`,
`cert-manager-issuers`, `cluster-pki-issuers` and `secrets` Ready,
`kubectl get clusterissuers` shows `cluster-ca` Ready, and
`kubectl get pods -A -o wide` shows one cloudflared and one authentik
server per node.

## Host-side assumptions (modules/cluster)

- containerd runtime handlers `runc` (default) and `nvidia` (gpu nodes);
  `crun` only with `clusterNode.crun.enable` (then flip `enableCrun` in
  `components/infra/runtime-classes.nix` and label those nodes).
- gpu nodes carry the label `nvidia.com/gpu.present=true`; c4130 also
  carries the taint `nvidia.com/gpu=vllm:NoSchedule`
  (`cluster/definition.nix`). Workloads that must run on every node
  tolerate it with `k8sLib.nodeTolerations`.
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
  apiservers (host network) reach webhook Services by ClusterIP,
  masqueraded to the node's flannel address; no extra firewall rule
  ([apps.md, Webhook and network](apps.md#webhook-and-network)).
