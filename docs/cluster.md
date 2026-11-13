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
2. On the host, as the owner of `/etc/nixos` (charlie until stage 2 of
   [Removing charlie from the servers](#removing-charlie-from-the-servers-2026-11),
   admin after): `cd /etc/nixos && git pull && sudo nixos-rebuild switch --flake /etc/nixos#<host>`
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

Check or force it (r440 as admin, admin kubeconfig; as charlie with `~charlie/…`
until stage 2 of [Removing charlie from the servers](#removing-charlie-from-the-servers-2026-11)):

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
  (x509, never copied off r440; in `~charlie` until stage 2 of charlie's removal).
- **People:** OIDC through authentik (group `cluster-admins` →
  `cluster-admin`): kubectl with kubelogin, or Headlamp at
  `https://k8s.neuros.is` (k8s/README.md).
- **API address:** `https://10.0.0.200:6443` on the LAN (keepalived VIP), or
  `https://kube-api.leaffish-monster.ts.net:6443` from anywhere on the
  tailnet (Tailscale Service, below).

### SSH between the hosts

Every host (the servers and Famine) has the same ssh client config,
`modules/programs/ssh.nix`, so `ssh c4130` works without options, from a
desktop and from one server to the next:

- `/etc/ssh/ssh_config` has a `Host` block for `c4130 r440 m2mini` and their
  `*.leaffish-monster.ts.net` names (names only, no IPs): `User admin`,
  `ForwardAgent yes`, `IdentitiesOnly yes`, and an `IdentityFile` that holds
  only the **public** half of the YubiKey's `ssh:admin` resident key (taken
  from admin's authorized keys, `modules/system/admin.nix`). With a public
  `IdentityFile`, ssh offers exactly that key from the agent, local or
  forwarded, and no other. No key handle is deployed anywhere.
- `/etc/ssh/ssh_known_hosts` pins each server's ed25519 host key
  (`cluster/definition.nix`, `nodes.<n>.sshHostKey`) for its name, FQDN,
  LAN and tailnet address (plus the bond0 addresses 10.25.0.1/.2). Tailscale
  SSH presents the same host keys. After a reinstall, update `sshHostKey`
  and the host's `.sops.yaml` anchor together.
- The agent must hold the `ssh:admin` key: on Linux `ssh-add -K` with the
  YubiKey plugged in (or `ssh-keygen -K` once, then `ssh-add` the
  `id_ed25519_sk_rk_admin` file it writes). The servers run no agent of
  their own; they use the forwarded one (sudo's hardware factor needs it
  too, [auth.md](auth.md)).
- By IP (e.g. over the LAN when Tailscale is down) the block does not
  apply: `ssh -A admin@10.0.0.95`. c4130's remote builds
  (`nixremote@10.25.0.2`, `hosts/c4130/builder.nix`) keep their own user
  and key for the same reason.
- Agent forwarding lets root on the host you are on use your key while you
  are connected (relay caveat in [auth.md](auth.md)).

**Windows** (Win32-OpenSSH 8.9 or newer): set the `ssh-agent` service to
Automatic and start it, then in `%USERPROFILE%\.ssh`, with the YubiKey
plugged in, run `ssh-keygen -K` and `ssh-add .\id_ed25519_sk_rk_admin`
(details: [auth.md](auth.md), "Clients: forwarding the agent"). In
`%USERPROFILE%\.ssh\config`:

```
Host c4130 r440 m2mini c4130.leaffish-monster.ts.net r440.leaffish-monster.ts.net m2mini.leaffish-monster.ts.net
  User admin
  ForwardAgent yes
  IdentitiesOnly yes
  IdentityFile ~/.ssh/id_ed25519_sk_rk_admin.pub
```

and copy the three host-key lines from any server's
`/etc/ssh/ssh_known_hosts` into `%USERPROFILE%\.ssh\known_hosts`, or check
the fingerprint at the first connection against `sshHostKey`.

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
`modules/system/sops.nix`; the cluster's app Secrets in
`k8s/secrets/<namespace>/<name>.sops.yaml`, applied by Flux:
k8s/README.md, "Secrets"); every other secret lives outside git.

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
| Cluster PKI (CA keys + leaves) | `r440:~admin/.local/share/cluster-pki/neurosis` (back it up; in `~charlie` until stage 2 of [Removing charlie from the servers](#removing-charlie-from-the-servers-2026-11)) | `cluster-pki` (docs/pki.md) |
| Node keys and certs | `/var/lib/kubernetes/secrets/` on each node | `cluster-pki deploy` |
| `cert-manager/cluster-ca` (workload intermediate CA key, `tls.crt` = intermediate + root, `tls.key`, `ca.crt` = root), **pending ceremony** | sops file `k8s/secrets/cert-manager/cluster-ca.sops.yaml` in git (admins + `&flux`) → Kubernetes Secret, applied by the Flux Kustomization `secrets` (owns it: prune, hand edits reverted within 10 min). Live until then: a self-signed root that cert-manager made, in the cluster only | at the ceremony: key made in tmpfs, signed by the YubiKey root, encrypted straight from tmpfs with `sops` into that path, PR, merge; then the tmpfs is shredded (docs/pki-migration-plan.md, nodes F and G). Renewal (every 2 y) is the same, by hand |
| Root CA cert and attestations (public, not secret), **pending ceremony** | `cluster/pki/` in git (`root-ca.pem`, `attest-9c.pem`, `attest-f9.pem`) | the ceremony (docs/pki.md, "YubiKey root CA") |
| `authentik/authentik-secrets` | sops file `k8s/secrets/authentik/authentik-secrets.sops.yaml` in git (admins + `&flux`) → Kubernetes Secret, applied by the Flux Kustomization `secrets` (owns it: prune, hand edits reverted within 10 min) | you: `sops k8s/secrets/authentik/authentik-secrets.sops.yaml`, PR, merge, restart its readers (k8s/README.md, "Secrets", "authentik") |
| `headlamp/headlamp-oidc` | sops file `k8s/secrets/headlamp/headlamp-oidc.sops.yaml` in git (admins + `&flux`) → Kubernetes Secret, applied by the Flux Kustomization `secrets` (owns it: prune, hand edits reverted within 10 min) | you: `sops k8s/secrets/headlamp/headlamp-oidc.sops.yaml`, PR, merge, restart its readers (k8s/README.md, "Secrets", "Headlamp") |
| `open-webui/open-webui-secrets` | sops file `k8s/secrets/open-webui/open-webui-secrets.sops.yaml` in git (admins + `&flux`) → Kubernetes Secret, applied by the Flux Kustomization `secrets` (owns it: prune, hand edits reverted within 10 min) | you: `sops k8s/secrets/open-webui/open-webui-secrets.sops.yaml`, PR, merge, restart its readers (k8s/README.md, "Secrets", "Open WebUI") |
| `cloudflared/tunnel-credentials` | sops file `k8s/secrets/cloudflared/tunnel-credentials.sops.yaml` in git (admins + `&flux`) → Kubernetes Secret, applied by the Flux Kustomization `secrets` (owns it: prune, hand edits reverted within 10 min) | you: `sops k8s/secrets/cloudflared/tunnel-credentials.sops.yaml`, PR, merge, restart its readers (k8s/README.md, "Secrets", "Cloudflare tunnel") |
| `flux-system/webhook-token` (key `token`, no trailing newline) | sops file `k8s/secrets/flux-system/webhook-token.sops.yaml` in git (admins + `&flux`) → Kubernetes Secret, applied by the Flux Kustomization `secrets` (owns it: prune, hand edits reverted within 10 min) | you: `sops k8s/secrets/flux-system/webhook-token.sops.yaml`, PR, merge (nothing to restart), then update the GitHub secrets below (k8s/README.md, "Secrets") |
| `flux-system/sops-age` (Flux's age private key, recipient `&flux` in `.sops.yaml`) | Kubernetes Secret only (and so etcd and its backups); never in git, never on disk, never copied out | by hand, once per cluster: `age-keygen` piped into `kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=/dev/stdin` (k8s/README.md, "The bootstrap key"). Lost (or a new cluster): make a new one, set `&flux` to its recipient and `sops updatekeys` every `k8s/secrets/*/*.sops.yaml` with an admin key, PR, merge; until then the Kustomization `secrets` fails and the live Secrets keep their last values |
| `FLUX_WEBHOOK_TOKEN`, `FLUX_WEBHOOK_URL` | GitHub Actions secrets | by hand (docs/ci.md) |
| Cloudflare account cert (DNS routes) | `c4130:~admin/.cloudflared/cert.pem` (in `~charlie` until stage 2) | `cloudflared tunnel login` |
| harmonia signing key `r440-cache-1` | sops `harmonia-signing-key`, `secrets/r440.yaml` → `/run/secrets/harmonia-signing-key` (root, 0600); formerly `r440:/var/lib/secrets/harmonia.secret` | `nix key generate-secret` on r440 (exists) |
| Binary cache users (htpasswd) | sops `nix-cache-htpasswd`, `secrets/r440.yaml` → `/run/secrets/nix-cache-htpasswd` (root:nginx, 0640); formerly `r440:/var/lib/nix-cache/htpasswd` | by hand ([Binary cache](#binary-cache)) |
| Binary cache netrc, hosts | sops `nix-cache-netrc` in `secrets/{c4130,m2mini,famine}.yaml` → `/run/secrets/nix-cache-netrc` (root, 0600); formerly `/var/lib/nix-cache/netrc` on c4130 and m2mini, agenix on Famine (lost) | by hand (same) |
| `NIX_CACHE_NETRC` | GitHub Actions secret | by hand (docs/ci.md) |
| Remote-build SSH key `nixremote` | sops `nixremote-ssh-key`, `secrets/c4130.yaml` → `/run/secrets/nixremote-ssh-key` (root, 0600), formerly `c4130:/root/.ssh/nixremote`; public half authorized for user `nixremote` on r440 (`hosts/r440/builder.nix`) | `ssh-keygen` on c4130 (exists); used by `nix.buildMachines` in `hosts/c4130/builder.nix` (`ssh-ng://nixremote@10.25.0.2`) |
| Tailscale auth key (reinstall only) | `/var/lib/tailscale/authkey` (root, 0600) on the server being enrolled; delete after enrolment | admin console: pre-approved, non-ephemeral, tagged `tag:node` ([Tailscale](#tailscale)); read by `tailscaled-autoconnect` (`modules/server/tailscale.nix`) |
| Admin password (`admin`, the only wheel account after stage 2, next to charlie before; sudo asks for it; with `custom.auth.hardwareFactor` on, sudo asks for a FIDO2 key instead and the console for both, [docs/auth.md](auth.md)) | sops `admin-password` (**plaintext**, the one source of truth) in `secrets/common.yaml` → `/run/secrets-for-users/admin-password` (`neededForUsers`: ramfs, root 0400), every host. At each activation the host derives the yescrypt hash from it (`mkpasswd -m yescrypt --stdin`, reusing the current `/etc/shadow` hash while it still matches) into `/run/sops-password-hashes/admin` (root 0600, tmpfs), admin's `hashedPasswordFile` (`custom.sopsPasswords`, `modules/system/sops.nix`; set in `modules/system/admin.nix`). While a server is in stage 1 of [Removing charlie from the servers](#removing-charlie-from-the-servers-2026-11) (mutable users) that hash is written to `/etc/shadow` only when admin is created; a later change of `admin-password` reaches a stage-1 server only after stage 2 (or `sudo passwd admin` there). Lockout risk: a host that cannot decrypt `common.yaml` has no admin password, and after stage 2 root is locked and charlie gone (in stage 1 charlie's sudo still works); guarded by CI (recipients vs `.sops.yaml`) and the pre-switch check `sopsDecrypt`, which refuses the switch; a failed derivation at activation keeps the previous hash | you: `sops secrets/common.yaml`, edit `admin-password`, switch every host |
| charlie's password, Famine only | sops `charlie-password` (plaintext) in `secrets/famine.yaml` → `/run/secrets-for-users/charlie-password` (`neededForUsers`); the host derives `/run/sops-password-hashes/charlie` from it at activation, like admin's (`custom.sopsPasswords` in `modules/system/user.nix`; for the greeter and hyprlock, no sudo). Servers: charlie's password is the hash he set with `passwd`, kept in `/etc/shadow` (mutable users) until stage 2 removes him; the user holds the plaintext (offline, not in sops or the cloud environment) ([Removing charlie from the servers](#removing-charlie-from-the-servers-2026-11)); m2mini's old `/var/lib/secrets/charlie.passwd` is unused (it applied only when charlie was created), delete it in stage 2 | you: `sops secrets/famine.yaml`, edit `charlie-password` |
| sops-nix host identities | each host's SSH ed25519 host key `/etc/ssh/ssh_host_ed25519_key` (never in git); its `ssh-to-age` recipient is an anchor in `.sops.yaml`. Famine (no sshd) gets it from the `sopsHostKey` activation script (`modules/system/sops.nix`). A reinstalled host has a new key: update `.sops.yaml` and `sops updatekeys` before its first switch | sshd / activation |
| sops admin identities | YubiKey 5 serial 19830800 (travels with the user, never parked in a host; plugged in only deliberately and briefly, used ad hoc, see above): age-plugin-yubikey key in PIV slot 82 (`admin_yubikey` in `.sops.yaml`; PIN policy once, touch cached), plus the offline passphrase-protected backup age key file (`admin_backup`, stored offline with its passphrase). Both are recipients of every file. The same YubiKey holds the FIDO2 resident key `ssh:admin` (admin's SSH login). **Pending ceremony:** its PIV slot 9c is to hold the cluster's root CA key (ECDSA P-384, PIN and touch always, non-exportable, no backup; docs/pki.md, "YubiKey root CA"), a second PIV use next to slot 82; never `ykman piv reset` it. PIV and FIDO2 PINs are held by the user, offline (never in the cloud environment or in git); the PIV management key is random and PIN-protected on the key | `age-plugin-yubikey --generate`, `age-keygen \| age -p`, `ssh-keygen -t ed25519-sk -O resident` |
| YubiKey PIV PUK (serial 19830800) | sops `yubikey-19830800-piv-puk` in `secrets/admin.yaml` (admin keys only, never on a host). Unblocks the PIV PIN after 3 wrong tries; the PIN guards both PIV uses, the sops key in slot 82 and (pending ceremony) the root CA key in slot 9c. While the PIN is blocked the card can't decrypt, so `admin.yaml` is read with `admin_backup` | random, set 2026-11-13 |
| Desktop YubiKey files | sops `pam-yubikeys` in `secrets/famine.yaml` (`modules/system/yubikey.nix`, off until it exists). No separate ssh identity: ssh and git signing use the `ssh:admin` key from the agent (dropped `ssh-yubikey-5`, 2026-11-13). The old agenix files (`modules/age`, removed) and their keys are lost, as are Pestilence's agenix-only `key-pestilence`, `vpn-privkey`, `vpn-password`, `acme-cloudflare` | remake at Famine with the YubiKey ([docs/famine-sops.md](famine-sops.md)) |
| Pestilence Transmission `rpc-password` | **plaintext in git**, `hosts/Pestilence/servarr.nix` (archived host; excluded from the format check so the secrets guard stays quiet) | rotate it and move it to sops before restoring Pestilence |
| Cloud-session secrets | env vars of the Claude Code cloud environment: `TAIL_AUTH_KEY` (joins the session to the tailnet), and nothing else: no sudo password (admin's or charlie's) and no YubiKey PIN (`SERVER_PASSWORD` was removed 2026-11-13). The user runs every sudo command on the host | environment settings (CLAUDE.md, "Access from a cloud session") |
| Backups of charlie's server homes (temporary) | `r440:/var/backups/charlie-home/<host>.tar.zst` (root, 0600; dir 0700); they hold whatever charlie had: the cluster PKI (r440), the Cloudflare account cert (c4130), legacy `tls/` keys, SSH keys | [Removing charlie from the servers](#removing-charlie-from-the-servers-2026-11); delete them once the user OKs it |
| Binary-cache setup files (temporary) | `r440:/root/nix-cache-setup/*.pw,*.netrc` (root, 0700 dir) | made with the htpasswd; shred once every host's sops `nix-cache-netrc` (and r440's `nix-cache-htpasswd`) is live. Famine's netrc is already in `secrets/famine.yaml` |

None of the plaintext secrets may go into git, the Nix store or a command line (the Pestilence `rpc-password` is the one known exception, above); in git they exist only sops-encrypted (`secrets/`, `k8s/secrets/`).

## Removing charlie from the servers (2026-11)

Decision (2026-11-13): the servers (c4130, r440, m2mini) end up with one
local login, `admin`; the `charlie` account goes away on them (Famine keeps
charlie). It happens in two stages, each a plain `git pull && nixos-rebuild
switch` of `main`, so no switch both creates admin and removes charlie. The
switch between them is `custom.server.legacyCharlie.enable`
(`modules/server/legacy-charlie.nix`, default `true`). Stage 2 is per host:
one small PR per host sets `custom.server.legacyCharlie.enable = false;` in
that host's `hosts/<host>/configuration.nix` (m2mini, then r440, then
c4130), so each host leaves stage 1 only when its own PR is merged and
switched:

| | Before (main up to PR #36) | Stage 1 (PR #37; option on, the default) | Stage 2 (per-host PR; option off for that host) |
| --- | --- | --- | --- |
| Logins | charlie (wheel) | charlie (wheel, unchanged) and admin (wheel) | admin (wheel) only |
| `users.mutableUsers` | true | true | false |
| charlie's password | his `/etc/shadow` hash (set with `passwd`) | the same, untouched | account removed; `/home/charlie` stays |
| admin's password | – | sops `admin-password`, written to `/etc/shadow` once, when admin is created | sops `admin-password`, rewritten at every activation |
| root | as installed | untouched | locked (`!`) |
| `/etc/nixos` owner | charlie:root | charlie:root (tmpfiles `Z`) | admin:root (tmpfiles `Z`) |
| m2mini extras (dialout, fish, Nix trust) | charlie | charlie and admin | admin |
| c4130 GPU window kills GPU jobs of | charlie | charlie and admin | admin |

**Who runs what.** The user runs every command that needs sudo, in a
terminal on the host (`ssh -t <user>@<host> bash`; on m2mini the login shell
is fish, so start `bash` first). Blocks marked *user* say as which account.
Blocks marked *read-only* need no sudo; a cloud session may run them over
Tailscale SSH (as charlie before stage 1, as admin after), e.g.
`ssh -o ProxyCommand="tailscale --socket=/var/run/tailscale/tailscaled.sock nc %h %p" admin@$H bash -s <<'EOF' … EOF`
(give `</dev/null` to anything in the script that reads stdin).

**Why two stages** (nixpkgs 26.05 `nixos/modules/config/update-users-groups.pl`,
run at every activation):
- An existing `/etc/shadow` line is rewritten only when `mutableUsers` is
  false (`$sp_pwdp = "!" if !$spec->{mutableUsers}`, then the declared hash
  if there is one). With mutable users the line stays as it is.
- An account without a shadow line (a new one) gets its declared hash: the
  content of `hashedPasswordFile`, which is read for every user, else `!`.
- A user listed in `/var/lib/nixos/declarative-users` (written by the
  previous activation) and no longer declared is removed, mutable or not.
- uids: `/var/lib/nixos/uid-map` keeps every user ever created, and a
  re-created user gets its old uid back.

So in stage 1 nothing existing changes: charlie keeps his password and
root stays as it was; admin gets its hash once, at creation. Because the
users are mutable, a later change of `admin-password` does not reach
`/etc/shadow` on a stage-1 server (stage 2 applies it, or `sudo passwd
admin`). In stage 2 every shadow line is rewritten: root `!`, admin from
sops, charlie removed.

**What a rollback does** (`sudo nixos-rebuild switch --rollback`, or an
older generation in the boot menu):

| From | To | Result |
| --- | --- | --- |
| stage 1 | pre-sops generation | admin is removed (its home stays); charlie, his password and root are unchanged. Safe. |
| stage 2 | stage-1 generation | charlie comes back (same uid, home if still there) **without a password** (`!`: Tailscale SSH works, sudo does not); admin keeps its password and sudo. `/etc/nixos` goes back to charlie (as admin: `sudo chown -hR admin:root /etc/nixos` before pulling). Safe. |
| stage 2 | pre-sops generation | admin removed, charlie re-created with `!`, root locked: **nobody can sudo**. This is why stage 1 ends by deleting the pre-sops generations on each host, and why stage 2 checks that none is left. |

**uids and subuids.** admin, created in stage 1 while charlie exists, gets
the lowest free uid ≥ 1000 that is not in the uid-map (1001 or higher,
never charlie's; charlie is 1000 on m2mini, pinned; `id -u charlie`
elsewhere). After stage 2 charlie's uid and subuid range (100000:65536, in
`/var/lib/nixos/auto-subuid-map`) stay reserved; admin has its own
(typically 165536:65536), so charlie's rootless podman storage on r440
(`~/flint-swebench`, `~/.local/share/containers`) is not usable by admin as
is. `/home/charlie` and its files then show charlie's numeric uid as owner;
the home stays mode 0700.

**Order:** m2mini, then r440, then c4130 (GC first, outside 22:00–05:55
EST). One host at a time; finish a host, including the
[etcd health check](#etcd-health-check-any-member-in-bash), before the next.

### Stage 1: admin next to charlie (PR #37)

Preconditions: PR #37 is merged and CI was green (its secrets-guard checks
that every host is a recipient of the sops files it uses); on the host, the
pre-switch check `sopsDecrypt` refuses the switch if the host cannot decrypt
them. No admin account exists yet.

Per host (`H=m2mini`, then `r440`, then `c4130`):

**1. Inventory** (*read-only*, as charlie):

```sh
hostname; id charlie; id admin                 # admin: "no such user" (if it exists, stop and ask)
stat -c '%U:%G %a' /etc/nixos                  # charlie:root 755
git -C /etc/nixos status --short | head        # empty
ls -1d /nix/var/nix/profiles/system-*-link     # the generations, all pre-sops
```

**2. c4130 only: GC** (*user*, as charlie), outside 22:00–05:55 EST:

```sh
sudo nix-env -p /nix/var/nix/profiles/system --delete-generations +2 && sudo nix-collect-garbage
```

**3. Pull and switch** (*user*, as charlie, charlie's sudo password):

```sh
cd /etc/nixos && git pull --ff-only && git log -1 --oneline
sudo nixos-rebuild switch --flake /etc/nixos#$(hostname)
#   m2mini: add  --override-input m2mini-vendorfw path:/boot/vendorfw
echo "switch: $?"; systemctl --failed --no-legend
```

The output shows `sops: decrypts …` for each sops file (pre-switch check)
and no `removing user`, no `ERROR: no password for admin`.

**4. Verify** (*read-only*, as charlie):

```sh
id admin; id charlie                           # both in wheel; m2mini: both in dialout
getent passwd admin charlie | cut -d: -f1,3,7  # m2mini: both …/bin/fish
stat -c '%U:%G' /etc/nixos                     # charlie:root
```

Then the user logs in as admin over Tailscale SSH (from any machine on the
tailnet) and checks sudo:

```sh
ssh -t admin@$H bash          # Tailscale SSH as admin
sudo -v && echo "sudo ok"     # admin's password (sops admin-password)
sudo awk -F: '$1~/^(root|admin|charlie)$/ {print $1, substr($2,1,3)}' /etc/shadow
#   admin $y$   charlie (unchanged, e.g. $y$ or $6$)   root (unchanged)
```

If admin's sudo fails, stay in stage 1 and fix it as charlie: admin's
shadow line was probably written as `!` (the hash file was missing when
admin was created; look for `ERROR: no password for admin` in the switch
output). With mutable users a later switch does not repair it, so set it
once by hand: `sudo passwd admin` (as charlie) and type admin's password
from sops. Then verify again.

**5. etcd health check** (*user*, any account with sudo):
[etcd health check](#etcd-health-check-any-member-in-bash). Plus
`systemctl --failed`.

**6. Delete the pre-sops generations** (*user*, as admin, once 4 and 5
pass). Keep only the current generation and rewrite the boot menu, so
nobody can roll back or boot past stage 1 (see the rollback table):

```sh
sudo nix-env -p /nix/var/nix/profiles/system --delete-generations old
sudo /run/current-system/bin/switch-to-configuration boot   # boot menu: current only; does not activate
sudo nix-collect-garbage                                    # optional; frees the old closures (c4130: do it)
```

Check (*read-only*, as admin); every generation must say `admin=yes`:

```sh
for g in /nix/var/nix/profiles/system-*-link; do
  j=$(grep -o '/nix/store/[a-z0-9]*-users-groups\.json' "$g/activate" | head -1)
  printf '%s admin=%s\n' "${g##*/}" "$(grep -q '"name":"admin"' "$j" && echo yes || echo NO)"
done
```

Until step 6, a rollback to the previous (pre-sops) generation is safe and
only removes admin. After it, fix forward with a PR.

### Stage 2: charlie removed (one PR per host)

Start only when stage 1 is done on all three hosts. Then do the whole of
stage 2 for one host (m2mini, then r440, then c4130), including the etcd
check, before the next host's PR.

Once, for all hosts: the backup check below. Per host, before its PR:
- Stage 1 is done on this host: admin logs in and `sudo -v` works, and
  the generation check above says `admin=yes` for every generation
  (*read-only*, as admin).
- Nothing imperative that stage 2 would delete: immutable users remove
  every account and group that is not declared. *Read-only*, as admin, in
  bash; both lists must be empty (charlie is still declared here):

  ```sh
  comm -23 <(cut -d: -f1 /etc/passwd | sort) <(tr ' ' '\n' < /var/lib/nixos/declarative-users | sort)
  comm -23 <(cut -d: -f1 /etc/group | sort) <(tr ' ' '\n' < /var/lib/nixos/declarative-groups | sort)
  ```

- Backups of `/home/charlie`: done (2026-11-13), `r440:/var/backups/charlie-home/{c4130,r440,m2mini}.tar.zst`
  (root, 0600; directory 0700), all complete. Integrity check still to do
  (*user*, on r440, as admin; reads throttled, r440's root is the HDD that
  also holds etcd's WAL):

  ```sh
  Z=$(nix build --no-link --print-out-paths nixpkgs#zstd)/bin/zstd
  for h in c4130 r440 m2mini; do
    sudo systemd-run --scope -q -p 'IOReadBandwidthMax=/var/backups 60M' \
      "$Z" -tq /var/backups/charlie-home/$h.tar.zst && echo "$h ok" || echo "$h BAD"
  done
  sudo stat -c '%n %y' /var/backups/charlie-home/*.tar.zst    # backup times, for the next check
  ```

  Every archive must say `ok`. Files charlie changed after his backup are
  not in it: on the host, *user*, as admin,
  `sudo find /home/charlie -xdev -newermt '<that host's backup time>' | head`;
  if anything that matters shows up, ask the user (re-take that backup).

Then, on the host, steps 1 to 5:

**1. Stop charlie's login sessions** (*user*, as admin). **Never
`pkill -u charlie`:** uid 1000 is also the uid that container processes run
as (authentik's gunicorn on m2mini, about 8 pod processes on every node,
found 2026-11-13), so that would kill pods. Removing charlie doesn't touch
them: uid 1000 stays reserved in `/var/lib/nixos/uid-map` and those
processes just show as `1000` afterwards. End only charlie's systemd user
slice:

```sh
sudo loginctl terminate-user charlie 2>/dev/null; sleep 3
ps -u charlie -o pid=,cgroup=,comm= | grep 'user-1000\.slice'   # nothing listed (pods are in kubepods, leave them)
```

**2. Copy what is still used to `/home/admin`** (*user*, as admin):

| Host | Copied (to the same path under `/home/admin`) | Left in `/home/charlie` (and the backup) |
| --- | --- | --- |
| c4130 | `archive` (scripts, `nixos-backups`, notes, results), `vllm-hand` (the active hand harness), `.cloudflared` (account cert) | `vllm-sm70-work` (71 GB), `.cache`, `.triton`, `calib-cache`, `.claude`, dotfiles |
| r440 | `archive`, `.local/share/cluster-pki` (the cluster PKI and `admin.kubeconfig`, certs embedded), `.kube` | `flint-swebench` (68 GB, rootless podman under charlie's subuids), `vllm-sm70-work`, `work`, `prebuild`, `tls`, `.cache`, podman config/storage |
| m2mini | `archive` | `catenix` (a checkout; clone again if needed), `tls`, `.ssh` (admin uses the YubiKey), `.cache` |
| all | `.config/sops` if present (age-plugin-yubikey identity stub, not secret) | |

```sh
sudo bash -s <<'EOF'
set -euo pipefail
g=$(id -gn admin)
# Create every missing directory between /home/admin and $1, owned by admin.
mkdir_admin() {
  local d=$1 todo=()
  while [ "$d" != /home/admin ] && [ ! -e "$d" ]; do todo=("$d" "${todo[@]}"); d=$(dirname "$d"); done
  for d in "${todo[@]}"; do install -d -m 0700 -o admin -g "$g" "$d"; done
}
cp_item() {
  [ -e "/home/charlie/$1" ] || { echo "skip $1 (missing)"; return 0; }
  [ ! -e "/home/admin/$1" ] || { echo "/home/admin/$1 exists, not overwriting" >&2; return 1; }
  mkdir_admin "$(dirname "/home/admin/$1")"
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
find /home/admin ! -user admin | head          # nothing listed
# absolute paths into the old home (venv shebangs, configs) to fix by hand:
grep -rIl --exclude-dir=nixos-backups /home/charlie /home/admin 2>/dev/null | head -20 || true
EOF
```

**3. This host's PR**: add `custom.server.legacyCharlie.enable = false;`
to `hosts/<host>/configuration.nix` (only this host; the option's default
stays `true`, so the hosts not yet through stage 2 are unaffected), CI,
merge.

**4. Pull and switch** (*user*, as admin). admin cannot pull a checkout
charlie owns, so re-own it first (the switch's `Z` rule keeps it so):

```sh
sudo chown -hR admin:root /etc/nixos
cd /etc/nixos && git pull --ff-only && git log -1 --oneline
# c4130: GC first (stage 1, step 2), outside 22:00–05:55 EST
sudo nixos-rebuild switch --flake /etc/nixos#$(hostname)
#   m2mini: add  --override-input m2mini-vendorfw path:/boot/vendorfw
echo "switch: $?"; systemctl --failed --no-legend
```

The activation prints `removing user ‘charlie’`. Then the etcd health check.

**5. Verify.** *Read-only*, as admin:

```sh
getent passwd charlie || echo "charlie gone"; id admin
stat -c '%U:%G' /etc/nixos; find /etc/nixos ! -user admin | head    # admin:root, nothing listed
ls -ld ~ ~/archive && ls ~/archive | head
# r440: the moved kubeconfigs and the PKI
nix shell nixpkgs#kubectl -c kubectl --kubeconfig ~/.local/share/cluster-pki/neurosis/admin.kubeconfig get nodes </dev/null
nix run /etc/nixos#cluster-pki -- status --out ~/.local/share/cluster-pki/neurosis </dev/null | tail -5
# c4130: the account cert (read-only call)
ls -l ~/.cloudflared/cert.pem ~/archive/scripts/verify_vllm.py && cloudflared tunnel list </dev/null | head -3
# m2mini: groups and shell
id; getent passwd admin                      # dialout + wheel; …/bin/fish
```

*User*, as admin:

```sh
sudo -v && echo "sudo ok"
sudo awk -F: '$1~/^(root|admin)$/ {print $1, substr($2,1,3)}' /etc/shadow   # root !, admin $y$
[ "$(hostname)" = m2mini ] && sudo rm -f /var/lib/secrets/charlie.passwd    # unused since stage 1
```

If something is wrong: `sudo nixos-rebuild switch --rollback` returns to
the stage-1 generation (see the rollback table: charlie back without a
password, admin unchanged, `/etc/nixos` back to charlie). Revert this
host's PR too, or the next pull switches it to stage 2 again.

Then the next host, from its preconditions.

### Afterwards (needs the user)

- `/home/charlie` stays as it is until the user OKs deleting it:
  `sudo rm -rf --one-file-system /home/charlie` (on r440 this also frees
  the Nix GC root under `~/flint-swebench/podman-pkg`). Stray files in
  `/tmp` and `/var/tmp` with charlie's uid (`sudo find /tmp /var/tmp -xdev -uid <uid>`) go then too.
- The backups in `r440:/var/backups/charlie-home/` stay until the user OKs
  deleting them (they hold secrets; listed in [Secrets](#secrets-all-of-them)).
- Tailnet SSH policy: drop `charlie` as a login user for the servers
  (admin console); keep it wherever Famine needs it.
- `cluster-pki-deploy` runs as admin on r440 (after stage 2) and ssh-es as
  admin to the nodes: the tailnet SSH policy must allow admin from r440
  (`tag:node`) to the other nodes.
