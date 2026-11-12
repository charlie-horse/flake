# neurosis cluster: current state and operations

Three NixOS 26.05 servers run one Kubernetes cluster (v1.36). The NixOS side
(etcd, control plane, kubelet, containerd, keepalived, firewall) is
`modules/cluster/`, fed by `cluster/definition.nix`. Everything inside the
cluster is `k8s/` (catenix), deployed by Flux. How the cluster got here (the
October 2026 cut-over) is [history/cluster-handoff-2026-10.md](history/cluster-handoff-2026-10.md).

| Node | Arch | Roles | Notes |
| --- | --- | --- | --- |
| c4130 | x86_64 | etcd, control plane, worker | 2× V100 for the host's vLLM; tainted `nvidia.com/gpu=vllm:NoSchedule` (only one-per-node workloads tolerate it); root on SATA SSD RAID1 |
| r440 | x86_64 | etcd, control plane, worker | Nix builder for c4130; root is a slow HDD shared with etcd's WAL; holds the cluster PKI |
| m2mini | aarch64 (Asahi, 16 KiB pages) | etcd, control plane, worker | NVMe; authentik's PostgreSQL lives here |

The apiserver VIP is 10.0.0.200 (keepalived on every node, VRRP unicast on
the LAN). Every node runs kube-apiserver, controller-manager and scheduler
(the latter two leader-elected); the highest-priority node whose local
`/readyz` answers holds the VIP (c4130 150 > r440 100 > m2mini 50), so the
VIP survives any one node going down. Nodes reach each other over
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
export KUBECONFIG=~/.local/share/cluster-pki/neurosis/admin.kubeconfig
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

- **Admin (break-glass):** `r440:~/.local/share/cluster-pki/neurosis/admin.kubeconfig`
  (x509, never copied off r440).
- **People:** OIDC through authentik (group `cluster-admins` →
  `cluster-admin`): kubectl with kubelogin, or Headlamp at
  `https://k8s.neuros.is` (k8s/README.md).
- **API address:** `https://10.0.0.200:6443` on the LAN (keepalived VIP), or
  `https://kube-api.leaffish-monster.ts.net:6443` from anywhere on the
  tailnet (Tailscale Service, below).

## Tailscale

All three servers' Tailscale prefs are in Nix:
`modules/server/tailscale.nix` (shared flags, the live values they mirror,
how a reinstall logs in) and `server.tailscale.*` in each host's
`configuration.nix` (routes, tags). `tailscaled-set` runs `tailscale set`
with those flags on every start, so a hand-made `tailscale set` is undone
by the next boot or switch: change the Nix instead. Tailscale SSH is the
only way into the hosts; never turn `ssh` off.

Live prefs (2026-11-12, all 1.104.4, all `tag:node` on the control plane):

| Host | AdvertiseRoutes | AdvertiseTags | SSH, accept-dns, accept-routes, netfilter, SNAT, stateful filtering |
| --- | --- | --- | --- |
| c4130 | exit node + 10.0.1.0/24 | `tag:node` | on, on, off, on, on, off |
| r440 | exit node + 10.0.1.0/24 | none (tag from the admin console) | same |
| m2mini | exit node + 10.0.0.0/16 | none (tag from the admin console) | same |

Reinstall: put a tagged (`tag:node`), pre-approved auth key in
`/var/lib/tailscale/authkey` (root, 0600, typed or pasted, never on a
command line), switch, then delete the file. Without the file
`tailscaled-autoconnect` is skipped.

### Tailscale Service for the API (`svc:kube-api`)

Every control plane hosts the Tailscale Service `svc:kube-api`
(`cluster.apiserverTailscaleService`, `modules/cluster/tailscale-service.nix`):
TCP 6443 on the service's own TailVIP → `127.0.0.1:6443` on the node.
Clients use `kube-api.leaffish-monster.ts.net:6443`; Tailscale spreads them
over the hosts that advertise it. The unit is bound to `kube-apiserver`:
stopping the apiserver drains the node (`tailscale serve drain`), starting
it advertises the node again. TLS passes through to the apiserver, so its
leaves carry the name (`apiserverExtraSANs`). No firewall change: tailscaled
connects to the apiserver over `lo`. The apiserver sees such clients as
127.0.0.1.

Requirements: Tailscale ≥ 1.86 on the hosts (1.104.4), tagged hosts (all
three are `tag:node`); clients ≥ 1.94 need no `--accept-routes` (older Linux
clients do).

Admin console and policy file (once, before the first switch):

1. Services → Advertise → Define a Service: name `kube-api`, endpoint
   `tcp:6443`, description "solaris Kubernetes API".
2. Policy file: approve tag:node hosts automatically and let the admins
   reach it (adjust `src` to who should use kubectl):

   ```jsonc
   "tagOwners": {
     "tag:node": ["autogroup:admin"],          // already there
   },
   "autoApprovers": {
     "services": {
       "svc:kube-api": ["tag:node"],
     },
   },
   "grants": [
     { "src": ["autogroup:admin"], "dst": ["svc:kube-api"], "ip": ["tcp:6443"] },
   ],
   ```

   Without `autoApprovers`, approve each host by hand on the service's page
   (Service hosts → Approve).

Check (read-only), on a node and from a client:

```sh
tailscale serve status --json        # Services."svc:kube-api".TCP."6443"
tailscale debug prefs | jq .AdvertiseServices   # ["svc:kube-api"]
kubectl --server=https://kube-api.leaffish-monster.ts.net:6443 get --raw /readyz
```

Rollout (after the PR is merged):

1. Policy and service definition (above).
2. New apiserver leaves on r440 (the SAN list changed):
   `cd /etc/nixos && git pull && nix run /etc/nixos#cluster-pki -- --out ~/.local/share/cluster-pki/solaris`
   (reports 3 apiserver leaves issued), then one node at a time
   `nix run /etc/nixos#cluster-pki-deploy -- <node> --out ~/.local/share/cluster-pki/solaris`,
   paste the printed `sudo install` commands, `sudo systemctl restart kube-apiserver`
   and wait for `curl -sk https://127.0.0.1:6443/readyz` before the next
   node. The switch below does not restart the apiserver.
3. Switch the hosts one at a time (Changing a host, above): c4130 GC first
   and outside 22:00–05:55 EST; after each, `systemctl --failed`, the etcd
   check, `systemctl status tailscale-service-kube-api` and
   `tailscale debug prefs` (unchanged apart from AdvertiseServices).
4. kubeconfigs: `kubectl config set-cluster solaris --server=https://kube-api.leaffish-monster.ts.net:6443`
   (the CA stays the same).

## Secrets that live outside git

| Secret | Where | Made by |
| --- | --- | --- |
| Cluster PKI (CA keys + leaves) | `r440:~/.local/share/cluster-pki/neurosis` (back it up) | `cluster-pki` (docs/pki.md) |
| Node keys and certs | `/var/lib/kubernetes/secrets/` on each node | `cluster-pki deploy` |
| `authentik/authentik-secrets` | Kubernetes Secret | by hand (k8s/README.md, authentik) |
| `headlamp/headlamp-oidc` | Kubernetes Secret | by hand (Headlamp section) |
| `open-webui/open-webui-secrets` | Kubernetes Secret | by hand (Open WebUI section) |
| `cloudflared/tunnel-credentials` | Kubernetes Secret | by hand (Cloudflare tunnel section) |
| `flux-system/webhook-token` | Kubernetes Secret (no trailing newline) | by hand |
| `FLUX_WEBHOOK_TOKEN`, `FLUX_WEBHOOK_URL` | GitHub Actions secrets | by hand (docs/ci.md) |
| Cloudflare account cert (DNS routes) | `c4130:~charlie/.cloudflared/cert.pem` | `cloudflared tunnel login` |

None of these may go into git, the Nix store or a command line.
