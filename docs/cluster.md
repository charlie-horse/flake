# neurosis cluster: current state and operations

Three NixOS 26.05 servers run one Kubernetes cluster (v1.36). The NixOS side
(etcd, control plane, kubelet, containerd, keepalived, firewall) is
`modules/cluster/`, fed by `cluster/definition.nix`. Everything inside the
cluster is `k8s/` (catenix), deployed by Flux ([k8s/README.md](k8s/README.md)).
How the cluster got here: [history/cluster-handoff-2026-10.md](history/cluster-handoff-2026-10.md)
(the October 2026 cut-over) and [history/charlie-removal-2026-11.md](history/charlie-removal-2026-11.md)
(charlie → admin). Every secret: [secrets.md](secrets.md).

| Node | Arch | Roles | Notes |
| --- | --- | --- | --- |
| c4130 | x86_64 | etcd, control plane, worker | 2× V100 for the host's vLLM ([hosts/c4130.md](hosts/c4130.md)); tainted `nvidia.com/gpu=vllm:NoSchedule` (only one-per-node workloads tolerate it); root on SATA SSD RAID1 |
| r440 | x86_64 | etcd, control plane, worker | Nix builder for c4130 and the binary cache ([build-cache.md](build-cache.md)); root is a slow HDD shared with etcd's WAL |
| m2mini | aarch64 (Asahi, 16 KiB pages) | etcd, control plane, worker | NVMe; authentik's PostgreSQL lives here |

> **Unverified:** whether the old PKI directory on r440 (and the old leaves
> on each node) has been shredded after PKI P9 (#54); until then r440 still
> holds the pre-P9 cluster PKI in plaintext. The live CAs are in sops
> ([pki.md](pki.md)).

The apiserver VIP is 10.0.0.200 (keepalived on every node, VRRP unicast on
the LAN). Every node runs kube-apiserver, controller-manager and scheduler
(the latter two leader-elected); the highest-priority node whose local
`/readyz` answers holds the VIP (c4130 150 > r440 100 > m2mini 50), so the
VIP survives any one node going down. Nodes reach each other over
Tailscale (MagicDNS names) and the LAN (10.0.0.0/16).

## What runs where

- **Hosts (NixOS):** vLLM + LMCache on c4130 ([hosts/c4130-vllm.md](hosts/c4130-vllm.md)),
  GPU-window timers on c4130 (vLLM stopped 22:00–05:55 EST,
  [hosts/c4130.md](hosts/c4130.md)), the Nix builder and binary cache on
  r440 (harmonia behind nginx with basic auth, https://cache.neuros.is for
  every host; [build-cache.md](build-cache.md)).
- **Cluster ([k8s/README.md](k8s/README.md) has the full table):** flannel, CoreDNS, the
  NVIDIA device plugin, Flux; cert-manager (controller, cainjector, two
  webhook replicas; r440 and m2mini) with the workload CA, ClusterIssuer
  `cluster-ca`; cloudflared (the one Cloudflare tunnel, a replica per
  node); authentik (one server + worker per node); Headlamp; Open WebUI (on
  r440). Apps: [k8s/apps.md](k8s/apps.md).
- **Certificates:** the cluster's own (etcd, apiservers, kubelets, …) are
  issued by cert-manager in namespace `cluster-pki` and reach the hosts as
  sops files (`secrets/pki/<node>.yaml` → `/run/secrets/pki/`); workload TLS
  comes from cert-manager
  (`issuerRef: {kind: ClusterIssuer, name: cluster-ca}`). Why two:
  [pki.md](pki.md#bootstrap-pki-and-workload-pki).

Public hostnames all go through the tunnel `cluster`: `auth.neuros.is`
(authentik), `k8s.neuros.is` (Headlamp), `chat.neuros.is` (Open WebUI),
`flux.neuros.is` (Flux webhook, `/hook/` only), `cache.neuros.is` (r440's
Nix binary cache, basic auth; not in the cluster, [build-cache.md](build-cache.md)).

## The cluster definition (`cluster/definition.nix`)

Pure data: no functions, no Nix paths, no secrets. Everything that needs the
cluster layout reads it:

- `modules/cluster` (NixOS host config), via the `cluster` specialArg that
  `lib/system/mkServer.nix` passes in; also `modules/programs/ssh.nix`
  (host keys) and `modules/system/nix-cache.nix` (`binaryCache`);
- `k8s/components/infra/cluster-pki/leaves.nix` (cert subjects and SANs,
  which leaves each node gets; also read by `modules/cluster/pki-sops.nix`);
- `k8s/` (catenix manifests: CoreDNS IP, pod CIDR for flannel, tunnel
  ingress, …).

Keep the shape stable: add fields, don't rename them.

| Field | Type | Meaning |
| --- | --- | --- |
| `name` | string | cluster name (kube-controller-manager `--cluster-name`) |
| `domain` | string | tailnet DNS domain; nodes are `<name>.<domain>`, and MagicDNS resolves the bare `<name>` to the node's tailnet IP (etcd and the apiserver use that) |
| `vip`, `vipPrefixLength`, `virtualRouterId` | string, int, int | keepalived apiserver VIP (IPv4, on the LAN), the prefix it is added with, its VRRP router id |
| `apiserverPort` | int | kube-apiserver secure port (VIP and nodes) |
| `podCidr`, `nodeCidrMaskSize` | string, int | pod network (flannel, `--cluster-cidr`) and per-node pod subnet size |
| `serviceCidr`, `kubernetesServiceIP`, `dnsServiceIP` | string | `--service-cluster-ip-range`, its first IP (apiserver SAN), the CoreDNS Service IP (kubelet `clusterDNS`) |
| `clusterDomain` | string | cluster DNS domain |
| `apiserverTailscaleService` | optional string | name of the Tailscale Service (`svc:<name>`) every controlPlane node hosts for the apiserver port; clients use `<name>.<domain>:6443`. Absent = off. Read by `modules/cluster/tailscale-service.nix` ([below](#tailscale-service-for-the-api-svckube-api)) |
| `apiserverExtraSANs` | list of string | extra SANs on every apiserver leaf (must hold `<apiserverTailscaleService>.<domain>`; cert-manager reissues on change) |
| `oidc` | optional `{ issuerUrl; audiences; extraIssuers?; }` | kube-apiserver OIDC (JWT) login; absent = off. `extraIssuers`: list of `{ issuerUrl; audiences; }`, one more JWT authenticator each (authentik issues per provider, so every client, e.g. Headlamp, is its own issuer). Read by `modules/cluster/control-plane.nix` |
| `tunnel` | `{ name; id; }` | the one Cloudflare tunnel (locally managed), run in the cluster by `k8s/components/apps/cloudflared/` (one replica per node); every public hostname goes through it |
| `authentik`, `headlamp`, `openWebui`, `fluxWebhook` | `{ host; serviceIP; }` | public hostname on the tunnel and the fixed ClusterIP (static band of `serviceCidr`) the tunnel's nginx sidecar forwards to: `authentik/authentik-server` (`k8s/components/apps/authentik/`), `headlamp/headlamp` (`apps/headlamp.nix`), `open-webui/open-webui` (`apps/open-webui.nix`), Flux's webhook receiver (`k8s/components/flux/`) |
| `binaryCache` | `{ host; node; port; publicKey; }` | r440's Nix binary cache: public hostname on the tunnel, the node serving it, the port of the authenticated nginx on that node's `lanIP` (`hosts/r440/cache.nix`; not a Service, the sidecar forwards there), and the signing public key clients trust (`modules/system/nix-cache.nix`); [build-cache.md](build-cache.md) |
| `nodes.<name>` | attrs | keyed by hostname (= etcd member name = Kubernetes node name = cert CN suffix); fields below |

| `nodes.<name>.` field | Type | Meaning |
| --- | --- | --- |
| `system` | `"x86_64-linux"` \| `"aarch64-linux"` | |
| `lanIP`, `lanInterface` | string | LAN address (node InternalIP, VRRP, VXLAN) and NIC (VRRP interface) |
| `tailnetIP` | string | Tailscale address (what `<name>` resolves to) |
| `sshHostKey` | string | public half of `/etc/ssh/ssh_host_ed25519_key` (`ssh-ed25519 AAAA…`, no comment). Pinned in every host's `ssh_known_hosts` (`modules/programs/ssh.nix`); Tailscale SSH presents the same key. Its `ssh-to-age` is the host's anchor in `.sops.yaml`, so a reinstalled host changes both |
| `roles` | list of `"etcd"` \| `"controlPlane"` \| `"worker"` | what the node runs ([below](#nixos-side-modulescluster)) |
| `gpu` | bool | NVIDIA GPUs (container toolkit, `nvidia` RuntimeClass handler, `gpu.present` label) |
| `cri` | `"containerd"` \| `"cri-o"` | |
| `keepalivedPriority` | int | VRRP priority (the highest healthy node holds the VIP) |
| `labels` | attrs of string | extra kubelet `--node-labels` (`kubernetes.io/arch` etc. come from the kubelet) |
| `taints` | attrs of `{ key?; value; effect; }` | kubelet `--register-with-taints` (NixOS `kubelet.taints` shape) |
| `trustTailscale` | bool, default true | trust all of `tailscale0`; when false only this node's cluster ports are opened there (c4130) |
| `extraSANs` | list of string | extra SANs for this node's leaves |
| `kubeletConfig` | attrs | merged into the KubeletConfiguration (`services.kubernetes.kubelet.extraConfig`), e.g. `evictionHard` and image GC thresholds per node |
| `rollout.stage` | `"etcd"` \| `"controlPlane"` \| `"full"` (default) | which roles run ([history/cluster-handoff-2026-10.md](history/cluster-handoff-2026-10.md)) |

## NixOS side (`modules/cluster`)

Manual `services.kubernetes`: no easyCerts, no roles, no addons (CoreDNS,
flannel, the NVIDIA device plugin, RuntimeClasses and Flux are rendered
with catenix under `k8s/`). A server imports it with two specialArgs, both
passed by `lib/system/mkServer.nix`: `cluster` (the definition above) and
`hostName` (its key in `cluster.nodes`). What a node runs follows its
roles, limited by `clusterNode.stage` (`nodes.<n>.rollout.stage`):

| Role | Module | What |
| --- | --- | --- |
| etcd | `etcd.nix` | member `<name>`, `https://<name>:2380` |
| controlPlane | `control-plane.nix` | apiserver, controller-manager, scheduler (leader election) |
| controlPlane | `tailscale-service.nix` | Tailscale Service `svc:kube-api` → local apiserver ([below](#tailscale-service-for-the-api-svckube-api)) |
| worker | `node.nix` | kubelet, kube-proxy, containerd or cri-o, NVIDIA runtime on gpu nodes |
| every node | `keepalived.nix` | apiserver VIP, local `/readyz` check ([below](#apiserver-vip-keepalived)) |
| every node | `firewall.nix` | cluster ports open to the nodes only |
| every node | `pki-sops.nix` | keys and certs from `secrets/pki/<node>.yaml` ([pki.md](pki.md#on-the-nodes-runsecretspki)) |

Every key and cert is a string path under `/run/secrets/pki` (sops-nix), so
nothing secret is ever copied into `/nix/store`.

### Apiserver VIP (keepalived)

keepalived runs on every node: VRRP over the LAN interface, unicast between
the nodes' LAN IPs. The apiserver binds `0.0.0.0:6443`, so the VIP holder
serves the VIP itself; the highest-priority node whose **local**
`https://127.0.0.1:6443/readyz` answers holds it (a not-ready apiserver
drops its node to FAULT and the VIP moves). `/readyz` is readable
anonymously (`system:public-info-viewer`), so the check needs no client
cert. This replaced c4130's old LVS `virtual_server` (VIP:6443 →
10.0.0.95:6443 with an `SSL_GET /readyz` check).

A node without a local apiserver (none today: every node is a controlPlane)
would run HAProxy on :6443 instead, forwarding to the controlPlane nodes'
LAN IPs with a `/readyz` health check; the same local `/readyz` check then
tests "some apiserver is ready via me".

## Changing a host

1. Branch → PR → CI (`checks.yml`, [ci.md](ci.md)) → merge.
2. On the host, as admin (the owner of `/etc/nixos`, [Accounts](#accounts-on-the-servers)):
   `cd /etc/nixos && git pull && sudo nixos-rebuild switch --flake /etc/nixos#<host>`
   (m2mini adds `--override-input m2mini-vendorfw path:/boot/vendorfw`).
3. One host at a time; after each, `systemctl --failed` (`switch` exiting
   with status 4 means a unit failed) and the etcd check below. Never take
   two etcd members down together.
4. c4130: GC first (`sudo nix-env -p /nix/var/nix/profiles/system --delete-generations +2 && sudo nix-collect-garbage`),
   and switch outside the GPU window ([hosts/c4130.md](hosts/c4130.md)).

Never edit files in `/etc/nixos` or run `nix flake update` on a host, and
never `sudo git` there (root-owned files break the next pull until a switch
or boot re-owns the tree). Builds happen on r440 ([build-cache.md](build-cache.md)).

### etcd health check (any member, in bash)

```sh
D=/run/secrets/pki; n=$(hostname); C=$D/etcd-server-$n
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
   ([ci.md](ci.md), [k8s/README.md](k8s/README.md)).

Check or force it, with your OIDC kubeconfig or, on a node, the
break-glass one ([Access](#access)):

```sh
F="nix shell nixpkgs#fluxcd -c flux"                                # OIDC
F="sudo $(nix build --no-link --print-out-paths nixpkgs#fluxcd)/bin/flux --kubeconfig /etc/kubernetes/admin.kubeconfig"   # break-glass
$F get sources oci                    # Ready, SourceVerified
$F reconcile kustomization flux-system --with-source
$F get kustomizations                 # flux-system, cert-manager-issuers, cluster-pki-issuers, secrets Ready
```

Rendering on r440 needs a workaround (Nix's git fetcher fails on
`catenix/kubernetes-src` there):

```sh
git clone --depth 1 --branch v1.37.0 https://github.com/kubernetes/kubernetes /tmp/k8s-src
rm -rf /tmp/k8s-src/.git
nix build --override-input catenix/kubernetes-src path:/tmp/k8s-src .#k8s.manifests
```

## Access

- **Admin (break-glass):** on any node,
  `sudo kubectl --kubeconfig /etc/kubernetes/admin.kubeconfig …` (root
  only; the node's `admin-<node>` cert and the VIP; [pki.md](pki.md#break-glass)).
- **People:** OIDC through authentik (group `cluster-admins` →
  `cluster-admin`): kubectl with kubelogin, or Headlamp at
  `https://k8s.neuros.is` ([k8s/apps.md](k8s/apps.md)).
- **API address:** `https://10.0.0.200:6443` on the LAN (keepalived VIP), or
  `https://kube-api.leaffish-monster.ts.net:6443` from anywhere on the
  tailnet ([Tailscale Service](#tailscale-service-for-the-api-svckube-api)).

### Accounts on the servers

`admin` is the only login and the only wheel account on c4130, r440 and
m2mini; users are immutable, root is locked (`!`), and `charlie` is not
declared (Famine keeps him). `/etc/nixos` belongs to `admin:root` (mode
0755; a tmpfiles `Z` rule in `modules/server/default.nix` re-owns it at
every boot and switch). sudo asks for admin's password (sops
`admin-password`, [secrets.md](secrets.md)) or, with the hardware factor
on, a FIDO2 key ([auth.md](auth.md)). This is stage 2 of the
[charlie removal](history/charlie-removal-2026-11.md),
`custom.server.legacyCharlie.enable = false` in each host's
`configuration.nix`.

> **Unverified:** whether each host has switched to its stage-2 commit.
> Check with `getent passwd admin charlie` (only admin should print). On a
> host still in stage 1, charlie exists next to admin, users are mutable,
> and `/etc/nixos` belongs to charlie; follow the history doc there.

### Access from a cloud session

A cloud session (Claude Code) holds only `TAIL_AUTH_KEY`: no sudo password,
no YubiKey PIN, no cluster credentials ([secrets.md](secrets.md)). It
connects to the hosts only when the user has allowed it for the task.

- **Tailscale** is not preinstalled. Download the static
  `tailscale_<ver>_amd64.tgz` from pkgs.tailscale.com (piping the install
  script into `sh` gets blocked), then run
  `tailscaled --tun=userspace-networking --statedir=/var/lib/tailscale --socket=/var/run/tailscale/tailscaled.sock`
  in the background and
  `tailscale up --authkey="$TAIL_AUTH_KEY" --hostname=flake-cloud --accept-routes`.
  The node can get logged out after container restarts; if `status` shows
  no peers, run `up` again.
- **SSH** goes through Tailscale SSH (the tailnet SSH policy permits
  admin): install `openssh-client` with apt, then
  `ssh -o ProxyCommand="tailscale --socket=/var/run/tailscale/tailscaled.sock nc %h %p" admin@<host>`.
  On m2mini the login shell is fish: run sh syntax as
  `ssh … admin@m2mini bash -s <<'EOF' … EOF` (give `</dev/null` to
  anything in the script that reads stdin) or `ssh -t … bash`.
- **sudo** is run by the user, never by the session: write privileged steps
  as copy-paste blocks for the user to run on the host, as admin. The
  session runs only read-only checks that need no sudo (`journalctl -u vllm`
  and the break-glass kubeconfig need sudo).
- `/etc/nixos` is writable by admin, so `git pull` and building need no
  sudo; `nixos-rebuild switch` does.
- Over SSH, `pgrep -f <pattern>` matches its own `bash -c` command line; use
  `ps -ef | grep '[x]yz'` instead.

### SSH between the hosts

Every host has the same ssh client config (`modules/programs/ssh.nix`), so
`ssh c4130` works without options from a desktop and between the servers,
as admin with the YubiKey's `ssh:admin` key from a forwarded agent; host
keys are pinned from `nodes.<n>.sshHostKey`. Setup (Linux and Windows) and
details: [auth.md, SSH client](auth.md#ssh-client).

## Tailscale

All three servers' Tailscale prefs are in Nix: `modules/server/tailscale.nix`
(shared flags) and `server.tailscale.*` in each host's `configuration.nix`
(routes, tags). Tailscale SSH is the only way into the hosts; never turn
`ssh` off (from a session that came in over it, that locks everyone out).
Until 2026-11 only `services.tailscale.enable` was in Nix and the rest had
been set by hand; the flags reproduce the live prefs read on 2026-11-12
(`tailscale debug prefs`, 1.104.4):

| Pref (live) | Flag | Option |
| --- | --- | --- |
| RunSSH true | `--ssh=true` | `ssh` |
| CorpDNS true | `--accept-dns=true` (MagicDNS: the cluster names resolve through it) | `acceptDns` |
| RouteAll false | `--accept-routes=false` | `acceptRoutes` |
| AdvertiseRoutes 0/0 ::/0 + per host | `--advertise-exit-node=true`, `--advertise-routes=…` | `advertiseExitNode`, `advertiseRoutes` |
| NetfilterMode 2 (on) | `--netfilter-mode=on` | `netfilterMode` |
| NoSNAT false | `--snat-subnet-routes=true` | fixed |
| NoStatefulFiltering true | `--stateful-filtering=false` | fixed |
| ShieldsUp false | `--shields-up=false` | fixed |
| RunWebClient false | `--webclient=false` | fixed |
| AdvertiseTags | `--advertise-tags` (`up` only; `set` has no such flag) | `advertiseTags` |

How the NixOS module applies them:

- `tailscaled-set` (oneshot, at every start of the unit: boot and any switch
  that changes the flags) runs `tailscale set <flags>`. `set` only touches
  the prefs it names, so the flags must stay **exactly** the live state, or
  a switch silently changes routing or SSH on the node. A hand-made
  `tailscale set` is undone by the next boot or switch: change the Nix
  instead.
- `tailscaled-autoconnect` runs `tailscale up --auth-key … <flags>`, only
  when the node is logged out or stopped and only when the auth key file
  exists (`ConditionPathExists`). A running node is untouched.
- `tailscaled` runs with `TS_DEBUG_FIREWALL_MODE=nftables`;
  `useRoutingFeatures = "server"` turns on IP forwarding for the subnet
  routes and the exit node.

Live prefs (2026-11-12, all 1.104.4, all `tag:node` on the control plane):

| Host | AdvertiseRoutes | AdvertiseTags | SSH, accept-dns, accept-routes, netfilter, SNAT, stateful filtering |
| --- | --- | --- | --- |
| c4130 | exit node + 10.0.1.0/24 | `tag:node` | on, on, off, on, on, off |
| r440 | exit node + 10.0.1.0/24 | none (tag from the admin console) | same |
| m2mini | exit node + 10.0.0.0/16 | none (tag from the admin console) | same |

`advertiseTags` mirrors AdvertiseTags per host, so `up` never sees a pref
change; on a reinstall the tag comes from the tagged auth key.

**Reinstall:** generate a pre-approved, non-ephemeral auth key tagged
`tag:node` in the admin console. On the new host, as root (never in git,
the store or a command line):

```sh
sudo install -d -m 0700 /var/lib/tailscale
sudo sh -c 'umask 077; cat > /var/lib/tailscale/authkey'   # paste, ^D
```

Switch, then delete the file once the node shows up (the key is single-use
anyway). Without the file `tailscaled-autoconnect` is skipped.

### Tailscale Service for the API (`svc:kube-api`)

Every control plane hosts the Tailscale Service `svc:kube-api`
(`cluster.apiserverTailscaleService`, `modules/cluster/tailscale-service.nix`):
TCP 6443 on the service's own TailVIP → `127.0.0.1:6443` on the node.
Clients use `kube-api.leaffish-monster.ts.net:6443` (its own MagicDNS name);
Tailscale spreads them over the hosts that advertise it, next to the
LAN-only keepalived VIP. TLS passes through to the apiserver, so its
leaves carry the name (`apiserverExtraSANs`; the module asserts it). No
firewall change: tailscaled terminates the TailVIP connection and dials
`127.0.0.1:6443` over `lo`, which nixos-fw always accepts (also on c4130,
`trustTailscale = false`). The apiserver sees such clients as 127.0.0.1.

How: nixpkgs 26.05 has no serve/Services options in `services.tailscale`,
so a oneshot, `tailscale-service-kube-api`, waits up to 60 s for tailscaled
to be Running and applies a Services config file
(tailscale.com/kb/1589) with `tailscale serve set-config --all <file>`; the
file defines only `svc:kube-api`. The unit is bound to `kube-apiserver`
(`bindsTo`, `upheldBy`): stopping the apiserver runs
`tailscale serve drain svc:kube-api` (the node takes no new connections),
starting it advertises the node again. There is no `/readyz` check (the
keepalived VIP has one): a running but unready apiserver still gets
traffic.

> **Unverified:** `--all` replaced `--service=svc:kube-api` in c8fb285
> ("the provided config is for defining multiple services"). With `--all`
> the file is presumably the node's whole Services config, so any other
> Service configured on a node by hand would be replaced; the old comment
> ("replaces only this service's handlers") predates that change.

Requirements: Tailscale ≥ 1.86 on the hosts (1.104.4), tagged hosts (all
three are `tag:node`); clients ≥ 1.94 need no `--accept-routes` (older Linux
clients do). Until the admin console steps below are done, the node
advertises, unapproved.

Admin console and policy file (once, before the first switch):

1. Services → Advertise → Define a Service: name `kube-api`, endpoint
   `tcp:6443`, description "neurosis Kubernetes API".
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

> **Unverified:** whether this rollout is complete on all three hosts.

1. Policy and service definition (above).
2. New apiserver leaves (the SAN list changed): cert-manager reissues the
   `apiserver-<node>` Certificates at merge; run the export job
   ([pki.md](pki.md#export-job)) and merge its PR.
3. Switch the hosts one at a time ([Changing a host](#changing-a-host)): c4130 GC first
   and outside 22:00–05:55 EST; after each, `systemctl --failed`, the etcd
   check, `curl -skf https://127.0.0.1:6443/readyz` (`-f`: a not-ready
   apiserver still answers, with HTTP 500; the new leaf restarts it),
   `systemctl status tailscale-service-kube-api` and
   `tailscale debug prefs` (unchanged apart from AdvertiseServices).
4. kubeconfigs: `kubectl config set-cluster neurosis --server=https://kube-api.leaffish-monster.ts.net:6443`
   (the CA stays the same).

## Binary cache

r440's binary cache (https://cache.neuros.is), the remote builder and the
client config on every host: [build-cache.md](build-cache.md).

## Secrets

The inventory of every secret, and how to edit a sops file with the
YubiKey: [secrets.md](secrets.md).
