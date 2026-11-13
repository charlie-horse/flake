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
  the Nix builder and binary cache on r440 (harmonia behind nginx with basic
  auth, https://cache.neuros.is for every host; [Binary cache](#binary-cache)).
- **Cluster (`k8s/README.md` has the full table):** flannel, CoreDNS, the
  NVIDIA device plugin, Flux; cert-manager (controller, cainjector, two
  webhook replicas; r440 and m2mini) with the workload CA, ClusterIssuer
  `cluster-ca`; cloudflared (the one Cloudflare tunnel, a replica per
  node); authentik (one server + worker per node); Headlamp; Open WebUI (on
  r440).
- **Certificates:** the cluster's own (etcd, apiservers, kubelets, …) are
  files from `cluster-pki` on r440; workload TLS comes from cert-manager
  (`issuerRef: {kind: ClusterIssuer, name: cluster-ca}`). Why two:
  [pki.md](pki.md#bootstrap-pki-and-workload-pki).

Public hostnames all go through the tunnel `cluster`: `auth.neuros.is`
(authentik), `k8s.neuros.is` (Headlamp), `chat.neuros.is` (Open WebUI),
`flux.neuros.is` (Flux webhook, `/hook/` only), `cache.neuros.is` (r440's
Nix binary cache, basic auth; not in the cluster, [below](#binary-cache)).

## Changing a host

1. Branch → PR → CI (`checks.yml`) → merge.
2. On the host, as admin: `cd /etc/nixos && git pull && sudo nixos-rebuild switch --flake /etc/nixos#<host>`
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

Check or force it (r440 as admin, admin kubeconfig):

```sh
export KUBECONFIG=~/.local/share/cluster-pki/neurosis/admin.kubeconfig
nix shell nixpkgs#fluxcd -c flux get sources oci                    # Ready, SourceVerified
nix shell nixpkgs#fluxcd -c flux reconcile kustomization flux-system --with-source
nix shell nixpkgs#fluxcd -c flux get kustomizations                 # flux-system, cert-manager-issuers Ready
```

Rendering on r440 needs a workaround (Nix's git fetcher fails on
`catenix/kubernetes-src` there):

```sh
git clone --depth 1 --branch v1.37.0 https://github.com/kubernetes/kubernetes /tmp/k8s-src
rm -rf /tmp/k8s-src/.git
nix build --override-input catenix/kubernetes-src path:/tmp/k8s-src .#k8s.manifests
```

## Access

- **Admin (break-glass):** `r440:~admin/.local/share/cluster-pki/neurosis/admin.kubeconfig`
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

1. Policy and service definition (above).
2. New apiserver leaves on r440, as admin (the SAN list changed):
   `cd /etc/nixos && git pull && nix run /etc/nixos#cluster-pki -- --out ~/.local/share/cluster-pki/neurosis`
   (reports 3 apiserver leaves issued), then one node at a time
   `nix run /etc/nixos#cluster-pki-deploy -- <node> --out ~/.local/share/cluster-pki/neurosis`,
   paste the printed `sudo install` commands, `sudo systemctl restart kube-apiserver`
   and wait for `curl -skf https://127.0.0.1:6443/readyz` (`-f`: a
   not-ready apiserver still answers, with HTTP 500) before the next node.
   For r440 itself `cluster-pki-deploy` fails (it cannot ssh to itself):
   `sudo install` the changed pair straight from the PKI dir instead. The
   switch below does not restart the apiserver.
3. Switch the hosts one at a time (Changing a host, above): c4130 GC first
   and outside 22:00–05:55 EST; after each, `systemctl --failed`, the etcd
   check, `systemctl status tailscale-service-kube-api` and
   `tailscale debug prefs` (unchanged apart from AdvertiseServices).
4. kubeconfigs: `kubectl config set-cluster neurosis --server=https://kube-api.leaffish-monster.ts.net:6443`
   (the CA stays the same).

## Binary cache

r440's `/nix/store`, served read-only by harmonia (3.1.0) and signed with
`r440-cache-1` (secret key: sops `harmonia-signing-key` in
`secrets/r440.yaml`, formerly `r440:/var/lib/secrets/harmonia.secret`; public
half in `cluster/definition.nix`, `binaryCache.publicKey`), published as
**https://cache.neuros.is** with HTTP basic auth. Server side:
`hosts/r440/cache.nix`. Client side: `custom.nixCache`
(`modules/system/nix-cache.nix`), the same on every host: one substituter,
`https://cache.neuros.is?priority=50`, plus `netrc-file`.

```
client -> https://cache.neuros.is -> Cloudflare -> cloudflared (any node, hostNetwork)
       -> its nginx sidecar -> http://10.0.0.239:5080 -> nginx on r440 (basic auth)
       -> harmonia (unix socket /run/harmonia-cache.sock)
```

| Client | netrc (`machine cache.neuros.is login <user> password <pw>`) |
| --- | --- |
| c4130 | sops `nix-cache-netrc` in `secrets/c4130.yaml` → `/run/secrets/nix-cache-netrc` (root, 0600); formerly `/var/lib/nix-cache/netrc` |
| m2mini | sops `nix-cache-netrc` in `secrets/m2mini.yaml` → same path |
| Famine | sops `nix-cache-netrc` in `secrets/famine.yaml` → same path (the agenix copy is lost; the value came from the existing `famine` user, `r440:/root/nix-cache-setup/famine.netrc`) |
| GitHub Actions | secret `NIX_CACHE_NETRC` → `$RUNNER_TEMP` (docs/ci.md) |

r440 itself does not use it (it is the cache). Builds still go to r440
over bond0 (ssh, `nix.buildMachines` on c4130); only substitution moved.
**Cost for c4130:** paths it substitutes from r440 (the CUDA/torch/vLLM
closures, tens of GB) now go c4130 → Cloudflare → r440 at internet speed,
twice over the home uplink, instead of over the 25G link. Paths built
*for* c4130 on r440 are still copied back over ssh/bond0 (remote build),
so this hits mostly closures r440 already holds but c4130 lacks (e.g.
after a GC). To go back, revert the commit "c4130: substitute from
cache.neuros.is" (it restores harmonia's `10.25.0.2:5000` and bond0 port
5000 too).

cache.nixos.org (40) stays on every host and comes first: r440 is asked
only for what cache.nixos.org lacks (unfree CUDA builds, our own
packages), so cache.nixos.org's CDN carries the rest. Famine runs
nixpkgs-unstable and r440 26.05, so they share few paths. r440 holds no
aarch64 binaries (checked 2026-11-12: no aarch64 ELF in its store, no
binfmt or extra-platforms), so m2mini only gets arch-independent paths
(sources, fixed-output downloads, data) from it.

- **Auth.** harmonia has no client authentication (TLS only), and Nix
  authenticates to an HTTP substituter only with netrc (basic auth; it
  cannot send custom headers, so Cloudflare Access service tokens are
  out). nginx on r440 does `auth_basic` with the sops secret
  `nix-cache-htpasswd` (`/run/secrets/nix-cache-htpasswd`, root:nginx 0640),
  one user per client, and passes GET/HEAD to harmonia's unix socket
  (group nginx); other methods get 403.
- **Why nginx on r440 and not in the tunnel's sidecar.** The sidecar runs
  on all three nodes, so harmonia would have to be reachable without auth
  from all of them, i.e. from every pod (pod traffic to the LAN is
  masqueraded to the node IP), and the htpasswd would also be a Kubernetes
  Secret. On r440, harmonia listens only on the socket, and the secret is
  one file on the host that serves the store.
- **Reachability.** nginx listens on `:5080` on every address; its only
  consumer is the tunnel. The firewall opens 5080 to the nodes' LAN IPs
  and the VIP only (the connectors connect from those, or over lo on
  r440). tailscale0 is trusted on r440, so tailnet clients reach it too,
  with a password.
- **No shared caching.** harmonia marks NARs `Cache-Control:
  max-age=31536000`; nginx replaces that with `private, no-store` on every
  response (401s included), so Cloudflare's edge never stores one. Never add
  a "Cache Everything" page rule or a Cache Rule covering `cache.neuros.is`.
- **Compression.** harmonia sends NARs uncompressed; nginx gzips them
  (level 1; about half the bytes for binaries) and Nix decompresses
  transparently.
- **Failure.** The clients set `connect-timeout = 5` and `fallback = true`.
  After a failed query (unreachable, 5xx, or 401 from a missing or wrong
  netrc) Nix prints "disabling binary cache … for 60 seconds" and carries
  on with cache.nixos.org; a NAR whose download fails is built instead
  (tested with a missing netrc). A missing htpasswd on r440 gives 500 to
  everyone (fails closed).
- **Cloudflare.** NARs are large (the CUDA/torch closures are tens of GB)
  and go through the tunnel at r440's uplink speed. Cloudflare's terms
  forbid using the CDN for a disproportionate amount of large non-HTML
  content (video, big downloads) except through paid services built for
  it; this is private, low-volume use with nothing cached at the edge, but
  it is the kind of traffic those terms describe. The 100 s
  time-to-first-byte limit is no problem: harmonia streams at once.
  Browser Integrity Check or Bot Fight Mode may challenge Nix's curl
  client: turn them off for `cache.neuros.is` if requests get 403/503
  challenge pages.
- **Load on r440.** r440's root is the slow HDD that also holds etcd's WAL.
  Big NAR reads compete with etcd; watch etcd latency during large pulls.

### Setting it up (once, in this order)

1. Merge the PR. Flux rolls the cloudflared pods (the route has no DNS yet,
   so nothing reaches it). No host uses the cache until it is switched.
2. **r440:** `git pull`, switch, `systemctl --failed`, the etcd check. The
   switch moves harmonia from `10.25.0.2:5000` to the unix socket and
   starts nginx, which answers 500 until step 3. From here until c4130's
   switch (step 8), c4130's old substituter is refused: its builds still
   go to r440 over ssh and it still has cache.nixos.org, but every query
   to the dead URL is retried first. Do steps 3–8 in one sitting and don't
   deploy c4130 from an older checkout meanwhile.
3. **htpasswd on r440** (one random password per client; typed nowhere,
   never on a command line):

   ```sh
   cd ~ && umask 077
   users="ci famine c4130 m2mini"
   for u in $users; do openssl rand -hex 32 > "nix-cache-$u.pw"; done
   for u in $users; do printf '%s:' "$u"; openssl passwd -6 -stdin < "nix-cache-$u.pw"; done \
     > nix-cache.htpasswd   # becomes `nix-cache-htpasswd` in secrets/r440.yaml (sops)
   for u in $users; do
     { printf 'machine cache.neuros.is login %s password ' "$u"; cat "nix-cache-$u.pw"; } > "nix-cache-$u.netrc"
   done
   sed 's/cache.neuros.is/10.0.0.239/' nix-cache-ci.netrc > lan-check.netrc
   curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.239:5080/nix-cache-info                # 401
   curl -s --netrc-file lan-check.netrc http://10.0.0.239:5080/nix-cache-info | head -1   # StoreDir: /nix/store
   rm lan-check.netrc
   ```

   SHA-512 crypt, not bcrypt: nginx checks the password on every request
   (thousands of .narinfo lookups), and a 256-bit random password needs no
   slow hash. Revoke a client by deleting its line from
   `nix-cache-htpasswd` (`sops secrets/r440.yaml`) and switching r440
   (nginx reads the file per request).
4. **DNS** (outward; admin on c4130, account cert `~admin/.cloudflared/cert.pem`):
   `cloudflared tunnel route dns --overwrite-dns 59a275ca-be31-4f8d-99ce-c536eaf490f8 cache.neuros.is`.
   Check: `curl -sI https://cache.neuros.is/nix-cache-info` → 401,
   `cache-control: private, no-store`, no `cf-cache-status: HIT`;
   `curl -s --netrc-file nix-cache-ci.netrc https://cache.neuros.is/nix-cache-info`
   → `StoreDir: /nix/store`. Optional, in the dashboard: a Cache Rule
   "Bypass cache" for hostname `cache.neuros.is`.
5. **GitHub secret** `NIX_CACHE_NETRC` = the content of `nix-cache-ci.netrc`
   (Settings → Secrets and variables → Actions, or
   `gh secret set NIX_CACHE_NETRC --repo charlie-horse/flake < nix-cache-ci.netrc`).
6. **Netrc** (c4130, m2mini, Famine): `sops secrets/<host>.yaml`, key
   `nix-cache-netrc`, value the host's line from
   `r440:~/nix-cache-<host>.netrc` (never on a command line). sops-nix
   puts it at `/run/secrets/nix-cache-netrc` (root, 0600) on the next
   switch. Until then Nix uses cache.nixos.org alone, with a warning.
7. **m2mini:** switch (with its `--override-input`), `systemctl --failed`,
   the etcd check, then
   `sudo nix store info --store https://cache.neuros.is --option netrc-file /run/secrets/nix-cache-netrc`.
8. **c4130:** GC first, outside 22:00–05:55 EST, switch, `systemctl
   --failed`, the etcd check; then the same `nix store info` check.
9. **Famine:** `nix-cache-netrc` in `secrets/famine.yaml` (step 6), a PR,
   switch Famine.
10. On r440: `shred -u ~/nix-cache-*.pw ~/nix-cache-*.netrc`.

## Secrets (all of them)

The one inventory of every secret this repo depends on. Other docs keep
their setup steps but point here. sops-encrypted files are in git
(`secrets/*.yaml`, recipients in `.sops.yaml`, sops-nix:
`modules/system/sops.nix`); every other secret lives outside git.

**Editing or re-wrapping a sops file with the YubiKey** is ad hoc: no host
has sops, age-plugin-yubikey or pcscd installed permanently. On any machine
with the YubiKey plugged in, from a checkout of this repo, run
`nix shell nixpkgs#sops nixpkgs#age-plugin-yubikey` and start pcscd for the
session if the machine doesn't already run it. sops finds the YubiKey through
the identity stub in `~/.config/sops/age/keys.txt` (once per user:
`age-plugin-yubikey --identity > ~/.config/sops/age/keys.txt`; the stub is not
secret). Then run `sops …`, enter the PIV PIN and touch the key when it
blinks. On c4130 (no pcscd, no polkit rule for SSH sessions) this needs
root: as admin, `sudo -i`, enter the same `nix shell` (add
`nixpkgs#pcsclite` for `pcscd`), start
`PCSCLITE_HP_DROPDIR=$(nix build --no-link --print-out-paths nixpkgs#ccid)/pcsc/drivers pcscd --foreground --auto-exit &`
and run the identity and `sops` commands as root. pcscd exits by itself once
idle. The offline backup age key works anywhere without any of this
(`SOPS_AGE_KEY_FILE`).

| Secret | Where | Made by |
| --- | --- | --- |
| Cluster PKI (CA keys + leaves) | `r440:~admin/.local/share/cluster-pki/neurosis` (back it up; charlie's until 2026-11) | `cluster-pki` (docs/pki.md) |
| Node keys and certs | `/var/lib/kubernetes/secrets/` on each node | `cluster-pki deploy` |
| `cert-manager/cluster-ca` (workload root CA key) | Kubernetes Secret | cert-manager, in the cluster (declared in `k8s/`; never by hand, never copied) |
| `authentik/authentik-secrets` | Kubernetes Secret | by hand (k8s/README.md, authentik) |
| `headlamp/headlamp-oidc` | Kubernetes Secret | by hand (Headlamp section) |
| `open-webui/open-webui-secrets` | Kubernetes Secret | by hand (Open WebUI section) |
| `cloudflared/tunnel-credentials` | Kubernetes Secret | by hand (Cloudflare tunnel section) |
| `flux-system/webhook-token` | Kubernetes Secret (no trailing newline) | by hand |
| `FLUX_WEBHOOK_TOKEN`, `FLUX_WEBHOOK_URL` | GitHub Actions secrets | by hand (docs/ci.md) |
| Cloudflare account cert (DNS routes) | `c4130:~admin/.cloudflared/cert.pem` (charlie's until 2026-11) | `cloudflared tunnel login` |
| harmonia signing key `r440-cache-1` | sops `harmonia-signing-key`, `secrets/r440.yaml` → `/run/secrets/harmonia-signing-key` (root, 0600); formerly `r440:/var/lib/secrets/harmonia.secret` | `nix key generate-secret` on r440 (exists) |
| Binary cache users (htpasswd) | sops `nix-cache-htpasswd`, `secrets/r440.yaml` → `/run/secrets/nix-cache-htpasswd` (root:nginx, 0640); formerly `r440:/var/lib/nix-cache/htpasswd` | by hand ([Binary cache](#binary-cache)) |
| Binary cache netrc, hosts | sops `nix-cache-netrc` in `secrets/{c4130,m2mini,famine}.yaml` → `/run/secrets/nix-cache-netrc` (root, 0600); formerly `/var/lib/nix-cache/netrc` on c4130 and m2mini, agenix on Famine (lost) | by hand (same) |
| `NIX_CACHE_NETRC` | GitHub Actions secret | by hand (docs/ci.md) |
| Remote-build SSH key `nixremote` | sops `nixremote-ssh-key`, `secrets/c4130.yaml` → `/run/secrets/nixremote-ssh-key` (root, 0600), formerly `c4130:/root/.ssh/nixremote`; public half authorized for user `nixremote` on r440 (`hosts/r440/builder.nix`) | `ssh-keygen` on c4130 (exists); used by `nix.buildMachines` in `hosts/c4130/builder.nix` (`ssh-ng://nixremote@10.25.0.2`) |
| Tailscale auth key (reinstall only) | `/var/lib/tailscale/authkey` (root, 0600) on the server being enrolled; delete after enrolment | admin console: pre-approved, non-ephemeral, tagged `tag:node` ([Tailscale](#tailscale)); read by `tailscaled-autoconnect` (`modules/server/tailscale.nix`) |
| Admin password (`admin`, the only wheel account; sudo asks for it) | sops `admin-password` (**plaintext**, the one source of truth) in `secrets/common.yaml` → `/run/secrets-for-users/admin-password` (`neededForUsers`: ramfs, root 0400), every host. At each activation the host derives the yescrypt hash from it (`mkpasswd -m yescrypt --stdin`, reusing the current `/etc/shadow` hash while it still matches) into `/run/secrets-for-users/admin-password-hash`, admin's `hashedPasswordFile` (`custom.sopsPasswords`, `modules/system/sops.nix`; set in `modules/system/admin.nix`). The old `admin-password-hash` key is still in `common.yaml` but unused (nothing may declare it; drop it at the next YubiKey edit). Lockout risk: a host that cannot decrypt `common.yaml` has no admin password, and root is locked; guarded by CI (recipients vs `.sops.yaml`) and the pre-switch check `sopsDecrypt`, which refuses the switch; a failed derivation at activation keeps the previous hash | you: `sops secrets/common.yaml`, edit `admin-password`, switch every host |
| charlie's password, Famine only | sops `charlie-password` (plaintext) in `secrets/famine.yaml` → `/run/secrets-for-users/charlie-password` (`neededForUsers`); the host derives `/run/secrets-for-users/charlie-password-hash` from it at activation, like admin's (`custom.sopsPasswords` in `modules/system/user.nix`; the old `charlie-password-hash` key is unused; for the greeter and hyprlock, no sudo). Servers: no charlie since 2026-11 ([Removing charlie from the servers](#removing-charlie-from-the-servers-2026-11)); m2mini's old `/var/lib/secrets/charlie.passwd` is unused, delete it | you: `sops secrets/famine.yaml`, edit `charlie-password` |
| sops-nix host identities | each host's SSH ed25519 host key `/etc/ssh/ssh_host_ed25519_key` (never in git); its `ssh-to-age` recipient is an anchor in `.sops.yaml`. Famine (no sshd) gets it from the `sopsHostKey` activation script (`modules/system/sops.nix`). A reinstalled host has a new key: update `.sops.yaml` and `sops updatekeys` before its first switch | sshd / activation |
| sops admin identities | YubiKey 5 serial 19830800 (normally plugged into c4130; used ad hoc, see above): age-plugin-yubikey key in PIV slot 82 (`admin_yubikey` in `.sops.yaml`; PIN policy once, touch cached), plus the offline passphrase-protected backup age key file (`admin_backup`, stored offline with its passphrase). Both are recipients of every file. The same YubiKey holds the FIDO2 resident key `ssh:admin` (admin's SSH login). PIV and FIDO2 PINs = the cloud env's `SERVER_PASSWORD`; the PIV management key is random and PIN-protected on the key | `age-plugin-yubikey --generate`, `age-keygen \| age -p`, `ssh-keygen -t ed25519-sk -O resident` |
| YubiKey PIV PUK (serial 19830800) | sops `yubikey-19830800-piv-puk` in `secrets/admin.yaml` (admin keys only, never on a host). Unblocks the PIV PIN after 3 wrong tries | random, set 2026-11-13 |
| Desktop YubiKey files | sops `pam-yubikeys`, `ssh-yubikey-5` in `secrets/famine.yaml` (`modules/system/yubikey.nix`, off until they exist). The old agenix files (`modules/age`, removed) and their keys are lost, as are Pestilence's agenix-only `key-pestilence`, `vpn-privkey`, `vpn-password`, `acme-cloudflare` | remake at Famine with the YubiKey ([docs/famine-sops.md](famine-sops.md)) |
| Pestilence Transmission `rpc-password` | **plaintext in git**, `hosts/Pestilence/servarr.nix` (archived host; excluded from the format check so the secrets guard stays quiet) | rotate it and move it to sops before restoring Pestilence |
| Cloud-session secrets | env vars of the Claude Code cloud environment: `TAIL_AUTH_KEY` (joins the session to the tailnet) and admin's sudo password (see the admin row above; charlie's before the sops switch) | environment settings (CLAUDE.md, "Access from a cloud session") |
| Backups of charlie's server homes (temporary) | `r440:/var/backups/charlie-home/<host>.tar.zst` (root, 0600; dir 0700); they hold whatever charlie had: the cluster PKI (r440), the Cloudflare account cert (c4130), legacy `tls/` keys, SSH keys | [Removing charlie from the servers](#removing-charlie-from-the-servers-2026-11); delete them once the user OKs it |
| Binary-cache setup files (temporary) | `r440:/root/nix-cache-setup/*.pw,*.netrc` (root, 0700 dir) | made with the htpasswd; shred once every host's sops `nix-cache-netrc` (and r440's `nix-cache-htpasswd`) is live. Famine's netrc is already in `secrets/famine.yaml` |

None of the plaintext secrets may go into git, the Nix store or a command line (the Pestilence `rpc-password` is the one known exception, above).

## Removing charlie from the servers (2026-11)

Decision (2026-11-13): the servers (c4130, r440, m2mini) have one local
login, `admin`; the `charlie` account is gone from them (Famine keeps
charlie). In Nix that is the deletion of `modules/server/users.nix` and
m2mini's charlie settings (dialout, fish and Nix trust moved to admin), and
`/etc/nixos` owned by admin through a tmpfiles `Z` rule in
`modules/server/default.nix` (every boot and every switch). The switch
removes charlie from `/etc/passwd` but leaves `/home/charlie` and every file
charlie owns; this runbook backs the home up, moves what is still used to
`/home/admin`, and leaves the rest for the user to delete.

**What happens to the uids** (nixpkgs 26.05 `update-users-groups.pl`):
- `/var/lib/nixos/uid-map` keeps an entry for every user ever created, and
  entries are never removed. charlie's uid (1000 on m2mini, pinned; check the
  others with `id -u charlie`) stays reserved: no new user gets it, and a
  rollback brings charlie back with the same uid and its home intact.
- An existing admin keeps its uid. An admin created in the same activation
  that removes charlie would get the lowest uid ≥ 1000 that is neither in
  the current `/etc/passwd` (still listing charlie at that point) nor in the
  uid-map, i.e. 1001 or higher, never charlie's. (Don't do that anyway, see
  Preconditions.)
- Same for subordinate ids: charlie's `/etc/subuid` range (100000:65536)
  stays reserved in `/var/lib/nixos/auto-subuid-map`; admin has its own
  (typically 165536:65536). charlie's rootless podman storage on r440
  (`~/flint-swebench`, `~/.local/share/containers`) is owned by charlie's
  subuids and is not usable by admin's podman as is.
- After the switch `/home/charlie` and its files show charlie's numeric uid
  as owner; the home stays mode 0700, readable by root only.

**Order:** m2mini, then r440, then c4130 (GC first, outside 22:00–05:55
EST). One host at a time; finish a host (including the etcd check) before
the next.

### Preconditions

- The host already runs a generation **with** `admin` (the sops/admin switch)
  and admin works: Tailscale SSH as `admin@<host>` and `sudo -v` with admin's
  password. If not, do that switch first (charlie still present, charlie's
  sudo password) and verify admin, before anything here. In the 2026-11
  rollout that first switch is the PR #37 commit `6ddeffc` (admin + sops,
  charlie kept): `git -C /etc/nixos fetch && git -C /etc/nixos checkout
  6ddeffc`, switch, verify admin, then `git -C /etc/nixos checkout main` for
  the charlie removal. Never create admin
  and remove charlie in one switch: if the host cannot decrypt
  `secrets/common.yaml`, admin has no password, charlie is gone and root is
  locked.
- `main` contains the charlie removal (`hosts/m2mini/configuration.nix`
  shows `users.users.admin.extraGroups = [ "dialout" ]`).
- The user has said where the backups go. Below: `r440:/var/backups/charlie-home/<host>.tar.zst`
  (root, 0600; directory 0700). r440's root is the slow HDD that also holds
  etcd's WAL, so everything that reads or writes it here is throttled.

### Helpers (cloud session, bash)

```sh
set -o pipefail
read -rs ADMIN_PW                      # admin's password, pasted; never on a command line
S=/var/run/tailscale/tailscaled.sock
on()      { local h=$1; shift; ssh -o ProxyCommand="tailscale --socket=$S nc %h %p" "admin@$h" "$@"; }
asadmin() { on "$1" 'bash -s'; }       # stdin: a bash script, run as admin
asroot()  { { printf '%s\n' "$ADMIN_PW"; cat; } | on "$1" "sudo -S -p '' bash -s"; }
          # sudo -S takes the first line of stdin, bash reads the rest as the script
H=m2mini                               # then r440, then c4130
```

The remote commands are plain words, so they also work with fish as the
login shell (admin's on m2mini after the switch). The script arrives on the
same stdin as its commands: anything in it that may read stdin (nix,
nixos-rebuild, git) gets `</dev/null`, or it eats the rest of the script.

### 1. Inventory (before)

```sh
asroot $H <<'EOF'
cu=$(id -u charlie); echo "charlie uid $cu"; id admin
cat /var/lib/nixos/uid-map; echo; cat /etc/subuid
loginctl list-sessions --no-legend; ps -u charlie -o pid,etime,cmd --no-headers
# everything charlie owns outside its home (expected: /etc/nixos, stray /tmp files)
find / -xdev -uid "$cu" -not -path '/home/charlie/*' -not -path /home/charlie 2>/dev/null | head -50
du -sh /home/charlie; df -h / /home
stat -c '%U:%G %a' /etc/nixos; git -C /etc/nixos status --short | head
[ "$(hostname)" = c4130 ] && nvidia-smi --query-compute-apps=pid,used_memory --format=csv
EOF
```

Stop and ask the user if charlie still runs anything that matters (tmux, a
GPU job, rootless containers on r440), or owns something outside its home
other than `/etc/nixos` and `/tmp`/`/var/tmp` files. `/etc/nixos` must be
clean (no local changes).

### 2. Stop charlie's processes

```sh
asroot $H <<'EOF'
loginctl terminate-user charlie 2>/dev/null; sleep 3
pkill -TERM -u charlie; sleep 5; pkill -KILL -u charlie
ps -u charlie --no-headers | wc -l      # 0
EOF
```

### 3. Back up `/home/charlie`

Once, on r440:

```sh
asroot r440 <<'EOF'
install -d -m 0700 -o root -g root /var/backups/charlie-home; df -h /var/backups
EOF
```

c4130 and m2mini, streamed through the cloud session into r440 (r440's
write throttled to 40 MB/s):

```sh
OUT=/var/backups/charlie-home/$H.tar.zst
asroot $H <<'EOF' | { printf '%s\n' "$ADMIN_PW"; cat; } \
  | on r440 "sudo -S -p '' systemd-run --scope -q -p 'IOWriteBandwidthMax=/var/backups 40M' sh -c 'umask 077; cat > $OUT.part && test -s $OUT.part && mv $OUT.part $OUT'"
set -euo pipefail
Z=$(nix build --no-link --print-out-paths nixpkgs#zstd </dev/null)/bin/zstd
ionice -c3 nice -n19 tar -C /home --one-file-system --numeric-owner --xattrs --acls --sparse -cf - charlie \
  | nice -n19 "$Z" -T0 -6 -q
EOF
echo "exit: ${PIPESTATUS[*]}"             # 0 0 0
```

c4130's home is ~75 GB (71 GB of it `vllm-sm70-work`), so this takes as
long as the cloud session's tailnet link needs; run it in the background
and check the etcd health in between. If the link is too slow, write
the archive on c4130 first (`/var/backups/charlie-home/c4130.tar.zst`,
same tar line, ~138 GB free) and move that file to r440 afterwards.

r440 itself, in place (read and write on the same HDD, both throttled):

```sh
asroot r440 <<'EOF'
set -euo pipefail
OUT=/var/backups/charlie-home/r440.tar.zst
Z=$(nix build --no-link --print-out-paths nixpkgs#zstd </dev/null)/bin/zstd
umask 077
systemd-run --scope -q -p 'IOReadBandwidthMax=/home 40M' -p 'IOWriteBandwidthMax=/var/backups 40M' \
  sh -c "tar -C /home --one-file-system --numeric-owner --xattrs --acls --sparse -cf - charlie | $Z -T0 -6 -q > $OUT.part"
mv "$OUT.part" "$OUT"
EOF
```

A tar warning `file changed as we read it` (exit 1) means something still
writes there: back to step 2, then redo the backup.

### 4. Verify the backup

```sh
asroot $H <<'EOF'
find /home/charlie -xdev ! -type s | wc -l      # entries on disk (tar skips sockets)
EOF
asroot r440 <<EOF
set -euo pipefail
OUT=/var/backups/charlie-home/$H.tar.zst; L=/root/charlie-home-$H.list
Z=\$(nix build --no-link --print-out-paths nixpkgs#zstd </dev/null)/bin/zstd
stat -c '%U:%G %a %s' "\$OUT"                    # root:root 600 <bytes>
systemd-run --scope -q -p 'IOReadBandwidthMax=/var/backups 60M' \
  sh -c "\$Z -dc \$OUT | tar -tf - > \$L"        # zstd checks its checksums on the way
wc -l < "\$L"                                    # = the count above
grep -cE '^charlie/(archive|\.local/share/cluster-pki|\.cloudflared|\.kube)/' "\$L" || true
rm "\$L"
EOF
```

The two counts must be equal (tar warns "socket ignored" for sockets, which
the `find` leaves out). Don't continue on a mismatch or a zstd error.

### 5. `/etc/nixos` to admin, pull

Before the switch: admin cannot pull a checkout that charlie owns.

```sh
asroot $H <<'EOF'
chown -hR admin:root /etc/nixos; stat -c '%U:%G %a' /etc/nixos
EOF
asadmin $H <<'EOF'
cd /etc/nixos && git pull --ff-only </dev/null && git log -1 --oneline && git status --short
EOF
```

### 6. Switch

c4130: GC first (Changing a host), outside 22:00–05:55 EST. m2mini: add
`--override-input m2mini-vendorfw path:/boot/vendorfw`.

```sh
asroot $H <<'EOF'
nixos-rebuild switch --flake /etc/nixos#$(hostname) </dev/null 2>&1 | tail -40; echo "switch: ${PIPESTATUS[0]}"
getent passwd charlie || echo "charlie gone"; id admin
systemctl --failed --no-legend
stat -c '%U:%G' /etc/nixos; find /etc/nixos ! -user admin | head    # admin:root, nothing listed
EOF
```

The activation prints `removing user ‘charlie’`. Then the etcd health
check. If anything is wrong before step 7: `sudo nixos-rebuild switch
--rollback` brings charlie back unchanged (same uid, same home).

### 7. Copy what is still used to `/home/admin`

| Host | Copied (to the same path under `/home/admin`) | Left in `/home/charlie` (and the backup) |
| --- | --- | --- |
| c4130 | `archive` (scripts, `nixos-backups`, notes, results), `vllm-hand` (the active hand harness), `.cloudflared` (account cert) | `vllm-sm70-work` (71 GB), `.cache`, `.triton`, `calib-cache`, `.claude`, dotfiles |
| r440 | `archive`, `.local/share/cluster-pki` (the cluster PKI and `admin.kubeconfig`, certs embedded), `.kube` | `flint-swebench` (68 GB, rootless podman under charlie's subuids), `vllm-sm70-work`, `work`, `prebuild`, `tls`, `.cache`, podman config/storage |
| m2mini | `archive` | `catenix` (a checkout; clone again if needed), `tls`, `.ssh` (admin uses the YubiKey), `.cache` |
| all | `.config/sops` if present (age-plugin-yubikey identity stub, not secret) | |

```sh
asroot $H <<'EOF'
set -euo pipefail
g=$(id -gn admin)
cp_item() {
  [ -e "/home/charlie/$1" ] || { echo "skip $1 (missing)"; return 0; }
  [ ! -e "/home/admin/$1" ] || { echo "/home/admin/$1 exists, not overwriting" >&2; return 1; }
  install -d -m 0700 -o admin -g "$g" "/home/admin/$(dirname "$1")"
  cp -a "/home/charlie/$1" "/home/admin/$1"
  chown -hR "admin:$g" "/home/admin/$1"
  echo "copied $1"
}
case $(hostname) in
  c4130)  items="archive vllm-hand .cloudflared" ;;
  r440)   items="archive .local/share/cluster-pki .kube" ;;
  m2mini) items="archive" ;;
esac
for i in $items .config/sops; do cp_item "$i"; done
# absolute paths into the old home (venv shebangs, configs) to fix by hand:
grep -rIl --exclude-dir=nixos-backups /home/charlie /home/admin 2>/dev/null | head -20 || true
EOF
```

### 8. Verify as admin

```sh
asadmin $H <<'EOF'
cd /etc/nixos && git pull --ff-only </dev/null && git status --short | head
ls -ld ~ ~/archive && ls ~/archive | head
EOF
printf '%s\n' "$ADMIN_PW" | on $H "sudo -S -p '' -v" && echo "sudo ok"

# r440: the moved kubeconfigs and the PKI
asadmin r440 <<'EOF'
nix shell nixpkgs#kubectl -c kubectl --kubeconfig ~/.local/share/cluster-pki/neurosis/admin.kubeconfig get nodes </dev/null
nix shell nixpkgs#kubectl -c kubectl config get-contexts </dev/null    # ~/.kube/config (OIDC contexts need a browser login)
nix run /etc/nixos#cluster-pki -- status --out ~/.local/share/cluster-pki/neurosis </dev/null | tail -5
EOF

# c4130: the account cert (read-only call)
asadmin c4130 <<'EOF'
ls -l ~/.cloudflared/cert.pem ~/archive/scripts/verify_vllm.py && cloudflared tunnel list </dev/null | head -3
EOF

# m2mini: groups and shell
on m2mini 'id; getent passwd admin'                          # dialout + wheel; …/bin/fish
```

On m2mini also delete the unused `/var/lib/secrets/charlie.passwd`.

### 9. Afterwards (needs the user)

- `/home/charlie` stays as it is until the user OKs deleting it:
  `sudo rm -rf --one-file-system /home/charlie` (on r440 this also frees
  the Nix GC root under `~/flint-swebench/podman-pkg`). Stray files in
  `/tmp` and `/var/tmp` with charlie's uid (`find /tmp /var/tmp -xdev -uid <uid>`) go then too.
- The backups in `r440:/var/backups/charlie-home/` stay until the user OKs
  deleting them (they hold secrets; listed in [Secrets](#secrets-all-of-them)).
- Tailnet SSH policy: drop `charlie` as a login user for the servers
  (admin console); keep it wherever Famine needs it.
- `cluster-pki-deploy` now runs as admin on r440 and ssh-es as admin to the
  nodes: the tailnet SSH policy must allow admin from r440 (`tag:node`) to
  the other nodes.
