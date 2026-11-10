# k8s/ — in-cluster resources (catenix)

Every object in the cluster that is not a NixOS service is declared here as
a [catenix](https://github.com/charlie-horse/catenix) module and rendered to
`k8s/rendered/`, which Flux applies from git.

| File | Contents |
| --- | --- |
| `default.nix` | flake fragment `{ inputs, pkgs, lib }` → `packages.k8s-manifests`, `apps.render`, `apps.check-images`, `components` |
| `charts.nix` | published Helm charts, pinned by version + NAR hash (`catenix.lib.fetchChart`) |
| `components/*.nix` | one catenix module per rendered file (`validation.strict = true`) |
| `rendered/` | generated, committed; what Flux reads (never edit by hand) |

Cluster values (pod/service CIDRs, DNS IP, domain, nodes and their `gpu`
flag) come from `../cluster/definition.nix`, the same file the NixOS
modules read.

## Components

| Rendered file | What | Source |
| --- | --- | --- |
| `00-runtime-classes.yaml` | RuntimeClass `runc` (default handler) and `nvidia` (handler `nvidia`, nodeSelector `nvidia.com/gpu.present=true`); `crun` documented, off | hand-written |
| `05-rbac.yaml` | ClusterRoleBinding `system:kube-apiserver:kubelet-api-admin` (User `system:kube-apiserver`, the apiserver's kubelet client cert → ClusterRole `system:kubelet-api-admin`; without it `kubectl logs/exec/port-forward` get 403 from the kubelets); ClusterRoleBinding `oidc:cluster-admins` → `cluster-admin` (authentik group, inert until apiserver OIDC is on) | hand-written (what NixOS's disabled addon manager would create) |
| `07-local-storage.yaml` | StorageClass `local` (no provisioner, WaitForFirstConsumer): static hostPath PVs pinned to a node | hand-written |
| `10-flannel.yaml` | flannel VXLAN DaemonSet, `Network` = `podCidr`, kube-subnet-mgr, `--public-ip=$(status.hostIP)` (the node's LAN IP); no CNI install init containers (the host ships the plugin + conflist) | flannel chart v0.28.10 |
| `20-coredns.yaml` | CoreDNS, Service `kube-system/kube-dns` at `dnsServiceIP` (10.96.0.10), zone `clusterDomain` (cluster.local), 2 replicas | coredns chart 1.48.2 (CoreDNS 1.14.7) |
| `30-nvidia-device-plugin.yaml` | NVIDIA device plugin on `nvidia.com/gpu.present=true` nodes, `runtimeClassName: nvidia`, `DEVICE_ID_STRATEGY=index` (matches the host's index-named CDI spec) | nvidia-device-plugin chart 0.20.1 |
| `40-flux-system.yaml` | Flux v2.9.5: CRDs, source/kustomize/helm/notification controllers | fluxcd-community flux2 chart 2.19.1 |
| `50-flux-sync.yaml` | GitRepository `https://github.com/charlie-horse/flake` (public HTTPS, no secretRef), branch `main`; Kustomization `./k8s/rendered`, prune | hand-written, typed by the flux2 CRDs |
| `60-authentik.yaml` | authentik (SSO/OIDC): server + worker on amd64 (r440), PostgreSQL 17 StatefulSet on m2mini (hostPath PV), daily `pg_dump` CronJob to r440, blueprint for the `kubernetes` OIDC client. Secrets come from a hand-made Secret ([below](#authentik)) | authentik chart 2026.8.5 + hand-written |
| `90-podinfo.yaml` | podinfo smoke app (namespace `podinfo`), 3 replicas spread one per node (incl. the arm64 m2mini) | hand-written |

Every image is a multi-arch manifest list (linux/amd64 + linux/arm64);
`nix run .#k8s-check-images` checks it. The device plugin is pinned to the
gpu node by its nodeSelector (its image happens to be multi-arch too).

## Wiring (parts/packages.nix)

The flake is built with flake-parts; `flake.nix` imports
`./parts/packages.nix`, whose `perSystem` imports this directory with the
nodes' 26.05 nixpkgs (the flake's `nixpkgs` input):

```nix
# parts/packages.nix (abridged)
perSystem = { system, ... }: let
  pkgs = inputs.nixpkgs.legacyPackages.${system};
  k8s = import ../k8s {
    inherit inputs;
    inherit pkgs;
    lib = inputs.nixpkgs.lib;
  };
in {
  # only when system == "x86_64-linux":
  packages.k8s-manifests = k8s.packages.k8s-manifests;
  apps.k8s-render = k8s.apps.render;
  apps.k8s-check-images = k8s.apps.check-images;
};
```

So the outputs are `packages.x86_64-linux.k8s-manifests`,
`apps.x86_64-linux.k8s-render` and `apps.x86_64-linux.k8s-check-images`
(nothing for aarch64-linux).

`inputs.catenix` (in `flake.nix`) is the catenix flake
(`github:charlie-horse/catenix`);
`catenix.inputs.nixpkgs.follows = "nixpkgs"` avoids an extra nixpkgs.
Rendering is import-from-derivation (catenix runs `helm template` in a
derivation), so evaluating `k8s-manifests` builds the chart renders; it is
small (no compilers) and never part of a NixOS system closure.

## Refreshing `k8s/rendered/`

```sh
nix run .#k8s-render              # rewrite k8s/rendered/ from k8s/
nix run .#k8s-render -- --check   # exit 1 if k8s/rendered/ is stale
nix run .#k8s-check-images        # every image has amd64 + arm64
```

CI (x86_64-linux runner with Nix) on every push to `main` that touches
`k8s/**`, `cluster/**`, `parts/**`, `flake.nix` or `flake.lock` (full list
in `.github/workflows/k8s.yml`):

1. `nix run .#k8s-render`
2. `nix run .#k8s-check-images`
3. if `git status --porcelain k8s/rendered` is non-empty, commit
   `k8s/rendered` ("k8s: re-render") and push to `main`.

On pull requests CI runs `nix run .#k8s-render -- --check` instead, so a PR
either carries a fresh render or gets one on merge. Flux only ever reads
`main`, so nothing reaches the cluster before it is merged and rendered.

Validation: catenix type-checks every object against the Kubernetes v1.37
OpenAPI spec and the charts' CRDs at evaluation time (`validation.strict`),
and the render was checked with
`kubeconform -strict -kubernetes-version 1.36.3` (CRDs themselves have no
kubeconform schema and are skipped there; catenix types them).

## Bootstrap (fresh cluster, operator with an admin kubeconfig)

Flux can't run before the pod network and DNS do, so the first apply is
manual; afterwards Flux owns everything in `k8s/rendered/`, itself included.

```sh
kubectl apply --server-side -f k8s/rendered/00-runtime-classes.yaml \
  -f k8s/rendered/05-rbac.yaml \
  -f k8s/rendered/10-flannel.yaml -f k8s/rendered/20-coredns.yaml \
  -f k8s/rendered/30-nvidia-device-plugin.yaml
kubectl apply --server-side -f k8s/rendered/40-flux-system.yaml
kubectl wait --for condition=established --timeout=60s \
  crd/gitrepositories.source.toolkit.fluxcd.io \
  crd/kustomizations.kustomize.toolkit.fluxcd.io
kubectl apply --server-side -f k8s/rendered/50-flux-sync.yaml
flux get kustomizations --watch   # or: kubectl -n flux-system get ks
```

Smoke test: `kubectl -n podinfo get pods -o wide` shows one pod per node,
and `kubectl -n podinfo run curl --rm -it --restart=Never
--image=curlimages/curl -- curl -s podinfo.podinfo:9898` answers from each.

## Host-side assumptions (modules/cluster)

- containerd runtime handlers `runc` (default) and `nvidia` (gpu nodes);
  `crun` only with `clusterNode.crun.enable` (then flip `enableCrun` in
  `components/runtime-classes.nix` and label those nodes).
- gpu nodes carry the label `nvidia.com/gpu.present=true`.
- kubelet `--node-ip` = `lanIP` (so `status.hostIP` is the LAN address
  flannel uses), `clusterDNS` = `dnsServiceIP`, `clusterDomain`.
- `/opt/cni/bin` has the `flannel` and `portmap` plugins and
  `/etc/cni/net.d/10-flannel.conflist` is provided by NixOS.
- kube-controller-manager allocates node CIDRs (`--allocate-node-cidrs`,
  `--cluster-cidr` = `podCidr`, mask `nodeCidrMaskSize`).
- udp/8472 open between the nodes' LAN IPs (VXLAN). To run VXLAN over
  Tailscale instead, set `transport = "tailscale"` in
  `components/flannel.nix`.

## authentik

SSO for the cluster and its apps (`components/authentik.nix`). It runs
**in** the cluster but the cluster never depends on it: kubelets, the
control plane and the admin kubeconfig authenticate with x509 certs, Flux
and pods with service-account tokens. OIDC is only an extra way for people
to log in. If authentik is down, only those logins fail; the admin cert
(`r440:~/.local/share/cluster-pki/solaris/admin.kubeconfig`) is the
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
export KUBECONFIG=~/.local/share/cluster-pki/solaris/admin.kubeconfig
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

Public: **https://auth.neuros.is** (`cluster.authentik.host`), through a
**dedicated** Cloudflare tunnel, `solaris-auth`
(`cac462c4-7420-4ff3-9a40-c090a4e18737`). It runs on r440
(`hosts/r440/cloudflared.nix`), separate from c4130's chat tunnel. Through
a local nginx (below) it forwards to Service `authentik-server` at its
fixed ClusterIP (`cluster.authentik.serviceIP`, 10.96.0.20, in the static
band of the service CIDR), via r440's kube-proxy. authentik's pods also run on
r440, so SSO does not depend on c4130. The credential is
`r440:/var/lib/secrets/cloudflared/<tunnel>.json` (root, 0400). The DNS record
is a proxied CNAME to that tunnel:
`cloudflared tunnel route dns --overwrite-dns <tunnel> auth.neuros.is`
(charlie's `~/.cloudflared/cert.pem` on c4130).

Between cloudflared and the Service sits an nginx on `127.0.0.1:9180`
(r440). It *replaces* `X-Forwarded-For` and `X-Real-IP` with
Cloudflare's `Cf-Connecting-Ip`, which the edge always sets and a client
cannot forge. Cloudflare itself appends to a client-sent `X-Forwarded-For`,
and authentik reads the leftmost entry, so without nginx a client could pick
the IP authentik logs. authentik trusts `X-Forwarded-*` only from r440's
addresses (`AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS`). The tunnel is locally
managed (NixOS), so none of this is configured in the Cloudflare dashboard.

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
- the application `kubernetes`, which only `cluster-admins` may use.

On the apiserver, usernames and groups get the `oidc:` prefix, and
`05-rbac` binds `oidc:cluster-admins` to `cluster-admin`. It is on: the
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
kubectl config set-credentials solaris-oidc \
  --exec-api-version=client.authentication.k8s.io/v1 \
  --exec-interactive-mode=IfAvailable \
  --exec-command=kubectl --exec-arg=oidc-login --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://auth.neuros.is/application/o/kubernetes/ \
  --exec-arg=--oidc-client-id=kubernetes \
  --exec-arg=--oidc-extra-scope=profile --exec-arg=--oidc-extra-scope=email \
  --exec-arg=--oidc-extra-scope=offline_access
kubectl --user=solaris-oidc auth whoami   # oidc:<username>, groups oidc:cluster-admins
```

kubelogin serves its login page on `http://localhost:8000` (or `:18000` if
8000 is taken) on the machine running kubectl, which redirects to
auth.neuros.is. When kubectl runs over SSH, forward the port first:
`ssh -L 8000:localhost:8000 <host>`. Older kubectl without
`--exec-interactive-mode`: add `interactiveMode: IfAvailable` under the
user's `exec:` in the kubeconfig by hand.
