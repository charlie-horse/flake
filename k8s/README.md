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
| `05-rbac.yaml` | ClusterRoleBinding `system:kube-apiserver:kubelet-api-admin` (User `system:kube-apiserver`, the apiserver's kubelet client cert → ClusterRole `system:kubelet-api-admin`; without it `kubectl logs/exec/port-forward` get 403 from the kubelets) | hand-written (what NixOS's disabled addon manager would create) |
| `10-flannel.yaml` | flannel VXLAN DaemonSet, `Network` = `podCidr`, kube-subnet-mgr, `--public-ip=$(status.hostIP)` (the node's LAN IP); no CNI install init containers (the host ships the plugin + conflist) | flannel chart v0.28.10 |
| `20-coredns.yaml` | CoreDNS, Service `kube-system/kube-dns` at `dnsServiceIP` (10.96.0.10), zone `clusterDomain` (cluster.local), 2 replicas | coredns chart 1.48.2 (CoreDNS 1.14.7) |
| `30-nvidia-device-plugin.yaml` | NVIDIA device plugin on `nvidia.com/gpu.present=true` nodes, `runtimeClassName: nvidia`, `DEVICE_ID_STRATEGY=index` (matches the host's index-named CDI spec) | nvidia-device-plugin chart 0.20.1 |
| `40-flux-system.yaml` | Flux v2.9.5: CRDs, source/kustomize/helm/notification controllers | fluxcd-community flux2 chart 2.19.1 |
| `50-flux-sync.yaml` | GitRepository `https://github.com/charlie-horse/flake` (public HTTPS, no secretRef), branch `main`; Kustomization `./k8s/rendered`, prune | hand-written, typed by the flux2 CRDs |
| `90-podinfo.yaml` | podinfo smoke app (namespace `podinfo`), 3 replicas spread one per node (incl. the arm64 m2mini) | hand-written |

Every image is a multi-arch manifest list (linux/amd64 + linux/arm64);
`nix run .#k8s-check-images` checks it. The device plugin is pinned to the
gpu node by its nodeSelector (its image happens to be multi-arch too).

## Wiring (flake.nix)

```nix
let
  k8s = import ./k8s {
    inherit inputs;
    pkgs = inputs.nixpkgs-2605.legacyPackages.x86_64-linux;
    lib = inputs.nixpkgs-2605.lib;
  };
in {
  packages.x86_64-linux.k8s-manifests = k8s.packages.k8s-manifests;
  apps.x86_64-linux.k8s-render = k8s.apps.render;
  apps.x86_64-linux.k8s-check-images = k8s.apps.check-images;
}
```

`inputs.catenix` must be the catenix flake (`github:charlie-horse/catenix`);
`catenix.inputs.nixpkgs.follows = "nixpkgs-2605"` avoids an extra nixpkgs.
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
`k8s/**`, `cluster/definition.nix`, `flake.nix` or `flake.lock`:

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
