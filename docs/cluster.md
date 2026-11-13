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
2. New apiserver leaves on r440 (the SAN list changed):
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
4. **DNS** (outward; charlie on c4130, account cert):
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

| Secret | Where | Made by |
| --- | --- | --- |
| Cluster PKI (CA keys + leaves) | `r440:~/.local/share/cluster-pki/neurosis` (back it up) | `cluster-pki` (docs/pki.md) |
| Node keys and certs | `/var/lib/kubernetes/secrets/` on each node | `cluster-pki deploy` |
| `cert-manager/cluster-ca` (workload root CA key) | Kubernetes Secret | cert-manager, in the cluster (declared in `k8s/`; never by hand, never copied) |
| `authentik/authentik-secrets` | Kubernetes Secret | by hand (k8s/README.md, authentik) |
| `headlamp/headlamp-oidc` | Kubernetes Secret | by hand (Headlamp section) |
| `open-webui/open-webui-secrets` | Kubernetes Secret | by hand (Open WebUI section) |
| `cloudflared/tunnel-credentials` | Kubernetes Secret | by hand (Cloudflare tunnel section) |
| `flux-system/webhook-token` | Kubernetes Secret (no trailing newline) | by hand |
| `FLUX_WEBHOOK_TOKEN`, `FLUX_WEBHOOK_URL` | GitHub Actions secrets | by hand (docs/ci.md) |
| Cloudflare account cert (DNS routes) | `c4130:~charlie/.cloudflared/cert.pem` | `cloudflared tunnel login` |
| harmonia signing key `r440-cache-1` | sops `harmonia-signing-key`, `secrets/r440.yaml` → `/run/secrets/harmonia-signing-key` (root, 0600); formerly `r440:/var/lib/secrets/harmonia.secret` | `nix key generate-secret` on r440 (exists) |
| Binary cache users (htpasswd) | sops `nix-cache-htpasswd`, `secrets/r440.yaml` → `/run/secrets/nix-cache-htpasswd` (root:nginx, 0640); formerly `r440:/var/lib/nix-cache/htpasswd` | by hand ([Binary cache](#binary-cache)) |
| Binary cache netrc, hosts | sops `nix-cache-netrc` in `secrets/{c4130,m2mini,famine}.yaml` → `/run/secrets/nix-cache-netrc` (root, 0600); formerly `/var/lib/nix-cache/netrc` on c4130 and m2mini, agenix on Famine (lost) | by hand (same) |
| `NIX_CACHE_NETRC` | GitHub Actions secret | by hand (docs/ci.md) |
| Remote-build SSH key `nixremote` | sops `nixremote-ssh-key`, `secrets/c4130.yaml` → `/run/secrets/nixremote-ssh-key` (root, 0600), formerly `c4130:/root/.ssh/nixremote`; public half authorized for user `nixremote` on r440 (`hosts/r440/builder.nix`) | `ssh-keygen` on c4130 (exists); used by `nix.buildMachines` in `hosts/c4130/builder.nix` (`ssh-ng://nixremote@10.25.0.2`) |
| Tailscale auth key (reinstall only) | `/var/lib/tailscale/authkey` (root, 0600) on the server being enrolled; delete after enrolment | admin console: pre-approved, non-ephemeral, tagged `tag:node` ([Tailscale](#tailscale)); read by `tailscaled-autoconnect` (`modules/server/tailscale.nix`) |
| Admin password (`admin`, the only wheel account; sudo asks for it) | sops `admin-password-hash` (yescrypt hash) in `secrets/common.yaml` → `/run/secrets-for-users/admin-password-hash` (`neededForUsers`, `modules/system/admin.nix`), every host. The plaintext sits next to it as `admin-password`, for retrieval only: not a `sops.secrets` entry, never on a host. Lockout risk: a host that cannot decrypt `common.yaml` has no admin password, and root is locked | you: `mkpasswd -m yescrypt`, both into `sops secrets/common.yaml` |
| charlie's password hash, Famine only | sops `charlie-password-hash` in `secrets/famine.yaml` → `/run/secrets-for-users/charlie-password-hash` (`neededForUsers`, `custom.user.keepPassword` in `modules/system/user.nix`; for the greeter, no sudo). Servers: charlie has no password (`modules/server/users.nix`); m2mini's old `/var/lib/secrets/charlie.passwd` is unused, delete it | you: `mkpasswd -m yescrypt` → `sops secrets/famine.yaml` |
| sops-nix host identities | each host's SSH ed25519 host key `/etc/ssh/ssh_host_ed25519_key` (never in git); its `ssh-to-age` recipient is an anchor in `.sops.yaml`. Famine (no sshd) gets it from the `sopsHostKey` activation script (`modules/system/sops.nix`). A reinstalled host has a new key: update `.sops.yaml` and `sops updatekeys` before its first switch | sshd / activation |
| sops admin identities | YubiKey PIV (age-plugin-yubikey, `admin_yubikey` in `.sops.yaml`) and the offline passphrase-protected backup age key (`admin_backup`); recipients of every file | `age-plugin-yubikey`, `age-keygen` |
| Desktop YubiKey files | sops `pam-yubikeys`, `ssh-yubikey-5`, `ssh-yubikey-5c` in `secrets/famine.yaml` (`modules/system/yubikey.nix`, off until they exist). The old agenix files (`modules/age`, removed) and their keys are lost, as are Pestilence's agenix-only `key-pestilence`, `vpn-privkey`, `vpn-password`, `acme-cloudflare` | remake at Famine with both YubiKeys ([docs/famine-sops.md](famine-sops.md)) |
| Pestilence Transmission `rpc-password` | **plaintext in git**, `hosts/Pestilence/servarr.nix` (archived host; excluded from the format check so the secrets guard stays quiet) | rotate it and move it to sops before restoring Pestilence |
| Cloud-session secrets | env vars of the Claude Code cloud environment: `TAIL_AUTH_KEY` (joins the session to the tailnet) and the sudo password (charlie's until the sops switch; afterwards admin's, see the admin row above) | environment settings (CLAUDE.md, "Access from a cloud session") |
| Binary-cache setup files (temporary) | `r440:/root/nix-cache-setup/*.pw,*.netrc` (root, 0700 dir) | made with the htpasswd; shred once every host's sops `nix-cache-netrc` (and r440's `nix-cache-htpasswd`) is live. Famine's netrc is already in `secrets/famine.yaml` |

None of the plaintext secrets may go into git, the Nix store or a command line (the Pestilence `rpc-password` is the one known exception, above).
