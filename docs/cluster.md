# solaris cluster: current state and operations

Three NixOS 26.05 servers run one Kubernetes cluster (v1.36). The NixOS side
(etcd, control plane, kubelet, containerd, keepalived, firewall) is
`modules/cluster/`, fed by `cluster/definition.nix`. Everything inside the
cluster is `k8s/` (catenix), deployed by Flux. How the cluster got here (the
October 2026 cut-over) is [history/cluster-handoff-2026-10.md](history/cluster-handoff-2026-10.md).

| Node | Arch | Roles | Notes |
| --- | --- | --- | --- |
| c4130 | x86_64 | etcd, control plane, worker | 2× V100 for the host's vLLM; tainted `nvidia.com/gpu=vllm:NoSchedule` (only one-per-node workloads tolerate it); root on SATA SSD RAID1 |
| r440 | x86_64 | etcd, control plane, worker | Nix builder for c4130; root is a slow HDD shared with etcd's WAL; holds the cluster PKI |
| m2mini | aarch64 (Asahi, 16 KiB pages) | etcd, worker | NVMe; authentik's PostgreSQL lives here |

The apiserver VIP is 10.0.0.200 (keepalived). Nodes reach each other over
Tailscale (MagicDNS names) and the LAN (10.0.0.0/16).

## What runs where

- **Hosts (NixOS):** vLLM + LMCache on c4130 (`hosts/c4130/vllm/`, see its
  CLAUDE.md), GPU-window timers on c4130 (vLLM stopped 22:00–05:55 EST),
  the Nix builder on r440.
- **Cluster (`k8s/README.md` has the full table):** flannel, CoreDNS, the
  NVIDIA device plugin, Flux; cloudflared (the one Cloudflare tunnel, a
  replica per node); authentik (one server + worker per node); Headlamp;
  Open WebUI (on r440).

Public hostnames all go through the tunnel `cluster`: `auth.neuros.is`
(authentik), `k8s.neuros.is` (Headlamp), `chat.neuros.is` (Open WebUI),
`flux.neuros.is` (Flux webhook, `/hook/` only).

## Changing a host

1. Branch → PR → CI (`checks.yml`) → merge.
2. On the host: `cd /etc/nixos && git pull && sudo nixos-rebuild switch --flake /etc/nixos#<host>`
   (m2mini adds `--override-input m2mini-vendorfw path:/boot/vendorfw`).
3. One host at a time; after each, `systemctl --failed` and the etcd check
   below. Never take two etcd members down together.
4. c4130: GC first (`sudo nix-env -p /nix/var/nix/profiles/system --delete-generations +2 && sudo nix-collect-garbage`),
   and switch outside the GPU window.

Never edit files in `/etc/nixos` or run `nix flake update` on a host.

### etcd health check (any member, in bash)

```sh
D=/var/lib/kubernetes/secrets; n=$(hostname); C=$D/etcd-server-$n
E="sudo etcdctl --endpoints=https://r440:2379,https://c4130:2379,https://m2mini:2379 \
   --cacert=$D/etcd-ca.pem --cert=$C.pem --key=$C-key.pem"
$E endpoint health --cluster -w table     # 3 x true
$E endpoint status --cluster -w table     # 1 leader, raft index moving
$E member list -w table                   # r440/c4130/m2mini, unchanged
sudo journalctl -u etcd --since -5min | grep -iE 'x509|tls|handshake'   # empty
```

`snapshot save` takes exactly one endpoint: use `--endpoints=https://$n:2379`.

## Changing something in the cluster

1. Edit `k8s/` (or `cluster/definition.nix`), branch → PR. `render.yml`
   renders the PR's commit (and `checks.yml` runs).
2. Merge. `render.yml` pushes the render to GHCR as a cosign-signed OCI
   artifact and pings Flux's webhook; Flux applies it within seconds
   (docs/ci.md, k8s/README.md).

Check or force it (r440, admin kubeconfig):

```sh
export KUBECONFIG=~/.local/share/cluster-pki/solaris/admin.kubeconfig
nix shell nixpkgs#fluxcd -c flux get sources oci                    # Ready, SourceVerified
nix shell nixpkgs#fluxcd -c flux reconcile kustomization flux-system --with-source
```

Rendering on r440 needs a workaround (Nix's git fetcher fails on
`catenix/kubernetes-src` there):

```sh
git clone --depth 1 --branch v1.37.0 https://github.com/kubernetes/kubernetes /tmp/k8s-src
rm -rf /tmp/k8s-src/.git
nix build --override-input catenix/kubernetes-src path:/tmp/k8s-src .#k8s.manifests
```

## Access

- **Admin (break-glass):** `r440:~/.local/share/cluster-pki/solaris/admin.kubeconfig`
  (x509, never copied off r440).
- **People:** OIDC through authentik (group `cluster-admins` →
  `cluster-admin`): kubectl with kubelogin, or Headlamp at
  `https://k8s.neuros.is` (k8s/README.md).

## Secrets that live outside git

| Secret | Where | Made by |
| --- | --- | --- |
| Cluster PKI (CA keys + leaves) | `r440:~/.local/share/cluster-pki/solaris` (back it up) | `cluster-pki` (docs/pki.md) |
| Node keys and certs | `/var/lib/kubernetes/secrets/` on each node | `cluster-pki deploy` |
| `authentik/authentik-secrets` | Kubernetes Secret | by hand (k8s/README.md, authentik) |
| `headlamp/headlamp-oidc` | Kubernetes Secret | by hand (Headlamp section) |
| `open-webui/open-webui-secrets` | Kubernetes Secret | by hand (Open WebUI section) |
| `cloudflared/tunnel-credentials` | Kubernetes Secret | by hand (Cloudflare tunnel section) |
| `flux-system/webhook-token` | Kubernetes Secret (no trailing newline) | by hand |
| `FLUX_WEBHOOK_TOKEN`, `FLUX_WEBHOOK_URL` | GitHub Actions secrets | by hand (docs/ci.md) |
| Cloudflare account cert (DNS routes) | `c4130:~charlie/.cloudflared/cert.pem` | `cloudflared tunnel login` |

None of these may go into git, the Nix store or a command line.
