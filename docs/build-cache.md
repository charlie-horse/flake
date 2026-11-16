# Remote builder and binary cache (r440)

r440 does two jobs for the rest of the fleet:

- **Remote builder for c4130.** c4130 builds nothing itself; every derivation
  goes to r440 over ssh on the direct 2×25G link (`bond0`).
- **Binary cache.** r440's `/nix/store`, served read-only by harmonia behind
  nginx with HTTP basic auth, published as **https://cache.neuros.is**
  through the cluster's Cloudflare tunnel. c4130, m2mini, Famine and GitHub
  Actions substitute from it; r440 itself does not (it is the cache).

The two are independent: builds use ssh over `bond0`, substitution uses the
public URL (c4130 included).

| What | Where |
| --- | --- |
| r440: link, `nixremote` user, build concurrency | `hosts/r440/builder.nix` |
| r440: nix-daemon memory cap, zram | `hosts/r440/memory.nix` ([r440.md](hosts/r440.md)) |
| r440: ssh on `bond0` | `hosts/r440/firewall.nix` |
| r440: harmonia, nginx, cache firewall rule | `hosts/r440/cache.nix` |
| c4130: link, `nix.buildMachines`, `max-jobs = 0` | `hosts/c4130/builder.nix` |
| Every client: substituter, key, netrc | `custom.nixCache` (`modules/system/nix-cache.nix`) |
| Cache host, port, public key | `cluster/definition.nix`, `binaryCache` |
| Tunnel route `cache.neuros.is` | `k8s/components/apps/cloudflared` ([k8s/apps.md](k8s/apps.md)) |
| CI client | `.github/actions/nix-cache/action.yml` ([below](#github-actions)) |

All secrets named here are sops keys; their rows are in
[secrets.md](secrets.md).

## Remote builder

### The direct link

LACP bond `bond0` across both 25G ports (802.3ad, `miimon` 100, fast LACP,
`xmit_hash_policy = layer3+4` so parallel builds and copies hash onto both
cables), MTU 9000, no dhcpcd on the ports.

| | c4130 | r440 |
| --- | --- | --- |
| Address | `10.25.0.1/30` | `10.25.0.2/30` |
| Ports | `enp8s0f0np0`, `enp8s0f1np1` | `ens3f0np0`, `ens3f1np1` |

Cables are crossed: r440 `ens3f0np0` ↔ c4130 `enp8s0f1np1`, `ens3f1np1` ↔
`enp8s0f0np0`. r440 opens only ssh (22) on `bond0`; c4130 additionally
lets 10.25.0.2 reach the vLLM API port over it
([c4130-vllm.md](hosts/c4130-vllm.md)). Each side knows the other's pinned
host key under its link address too (`programs.ssh.knownHosts.<host>.hostNames`).

### c4130 side

- `nix.settings.max-jobs = 0`: c4130 never builds locally; its RAM belongs
  to vLLM + LMCache (~90 GB).
- `nix.buildMachines`: `ssh-ng://nixremote@10.25.0.2`, `x86_64-linux`,
  `maxJobs = 2`, `speedFactor = 4`, features `nixos-test benchmark
  big-parallel kvm`, and r440's host key as `publicHostKey`.
- `builders-use-substitutes = true`: r440 fetches what cache.nixos.org has
  itself instead of c4130 uploading it over the link.
- Key: sops `nixremote-ssh-key` in `secrets/c4130.yaml` →
  `/run/secrets/nixremote-ssh-key` (root, 0600; the whole OpenSSH ed25519
  private-key file with its trailing newline). The daemon's ssh reads it
  on every connection, so a new value needs no restart. Formerly
  `/root/.ssh/nixremote`.
- **r440 down:** build on c4130 with `--option max-jobs 4` and expect the
  RAM use.
- Check (root on c4130, so the user runs it):
  `sudo nix store ping --store ssh-ng://nixremote@10.25.0.2`.

### r440 side

- User `nixremote` (system user). Its only authorized key is c4130's
  builder key, restricted to `command="nix-daemon --stdio",restrict`.
  `nixremote` is in `trusted-users`.
- `system-features`: `nixos-test benchmark big-parallel kvm`.
- `nix.daemonCPUSchedPolicy = "batch"`, `daemonIOSchedClass = "idle"`:
  builds yield to etcd and the apiserver.
- r440 builds its own system too, and everything built for c4130 lands in
  its store, which is what the cache serves.

### Concurrency and memory

`builderMaxJobs = 2` at the top of `hosts/r440/builder.nix` and `maxJobs`
in `hosts/c4130/builder.nix` must be equal; with `nix.settings.cores = 8`
on r440 that is 2 builds × 8 cores. Keep `max-jobs × cores` at 16.

Why: each CUDA tree (the Flint build and, since vLLM fork 23ea1b6, LMCache)
runs `min(NIX_BUILD_CORES, 16)` nvcc jobs at ~1–2+ GiB each on CUTLASS
kernels. On 2026-11-04 two trees at 16 nvcc each exhausted r440's 46 GiB
and hung the box. 2 × 8 caps nvcc at 16 in total, like 1 × 16, while two
builds can still overlap.

The backstop is `hosts/r440/memory.nix`: 25% zram swap, and
`nix-daemon.service` (every build, c4130's included, since `nix-daemon
--stdio` forwards to the system daemon) capped at `MemoryHigh=32G` /
`MemoryMax=36G` / `MemorySwapMax=4G` with `OOMScoreAdjust=500`. A build
that hits the cap fails with an OOM kill instead of hanging r440; retry
it. Details: [r440.md](hosts/r440.md).

## Binary cache

```
client -> https://cache.neuros.is -> Cloudflare -> cloudflared (any node, hostNetwork)
       -> its nginx sidecar -> http://10.0.0.239:5080 -> nginx on r440 (basic auth)
       -> harmonia (unix socket /run/harmonia-cache.sock)
```

- **Server** (`hosts/r440/cache.nix`): harmonia (3.1.0 in nixpkgs 26.05)
  signs with `r440-cache-1` and listens only on the unix socket (group
  nginx, 0660; no TCP listener). nginx listens on `0.0.0.0:5080`
  (`cluster.binaryCache.port`) and passes GET/HEAD to the socket; every
  other method gets 403. harmonia's own `priority` setting is 30, the
  default for clients that set none; ours set 50.
- **Client** (`custom.nixCache`, the same on every host): one substituter
  `https://cache.neuros.is?priority=50`, `trusted-public-keys` from
  `cluster/definition.nix`, `netrc-file`, `connect-timeout = 5`,
  `fallback = true`. Enabled in `hosts/c4130/builder.nix`,
  `hosts/m2mini/nix.nix` and Famine's `custom.nixCache.enable`
  (`hosts/Famine/default.nix`). `modules/server/default.nix` imports the
  module for servers; desktops get it with `modules/` wholesale.
- **Priority.** cache.nixos.org (40) stays in `substituters` and comes
  first, so r440 is asked only for what cache.nixos.org lacks (unfree CUDA
  builds, our own packages). Famine runs nixpkgs-unstable and r440 26.05,
  so they share few paths. r440 holds no aarch64 binaries (checked
  2026-11-12: no aarch64 ELF in its store, no binfmt or extra-platforms),
  so m2mini gets only arch-independent paths (sources, fixed-output
  downloads, data).

### Secrets

| Secret | Where | Notes |
| --- | --- | --- |
| Signing key `r440-cache-1:<base64>` | sops `harmonia-signing-key`, `secrets/r440.yaml` (root 0600) | Read once at start (`LoadCredential`), so a change restarts harmonia. Public half: `cluster/definition.nix` `binaryCache.publicKey`. Formerly `/var/lib/secrets/harmonia.secret`. |
| htpasswd | sops `nix-cache-htpasswd`, `secrets/r440.yaml` (root:nginx 0640) | One `<user>:<SHA-512 crypt>` line per client (`ci famine c4130 m2mini`). nginx reads it per request. Missing file: 500 for everyone (fails closed). Formerly `/var/lib/nix-cache/htpasswd`. |
| netrc, c4130 | sops `nix-cache-netrc`, `secrets/c4130.yaml` → `/run/secrets/nix-cache-netrc` (root 0600) | Formerly `/var/lib/nix-cache/netrc`. |
| netrc, m2mini | same key in `secrets/m2mini.yaml`, same path | Formerly `/var/lib/nix-cache/netrc`. |
| netrc, Famine | same key in `secrets/famine.yaml`, same path | The agenix copy is lost; the value came from the `famine` user, `r440:/root/nix-cache-setup/famine.netrc`. |
| netrc, CI | GitHub Actions secret `NIX_CACHE_NETRC` → `$RUNNER_TEMP/nix-cache.netrc` | [GitHub Actions](#github-actions). |

A netrc is one line, `machine cache.neuros.is login <user> password <pw>`.
Nix reads `netrc-file` on every download, so a new value applies without
restarting nix-daemon. `custom.nixCache.netrcFile` is a string so the file
never enters the store, and an assertion refuses a store path.

> **Unverified:** whether the pre-sops files (`/var/lib/secrets/harmonia.secret`,
> `/var/lib/nix-cache/htpasswd` on r440, `/var/lib/nix-cache/netrc` on c4130
> and m2mini) and the setup files on r440 (`~/nix-cache-*.pw`,
> `~/nix-cache-*.netrc`, `/root/nix-cache-setup/`) have been shredded. Check
> on the hosts; shred any that remain.

### Design

- **Auth.** harmonia has no client authentication (TLS only), and Nix
  authenticates to an HTTP substituter only with netrc (basic auth; it
  cannot send custom headers, so Cloudflare Access service tokens are
  out). Hence nginx with `auth_basic`, one user per client.
- **Why nginx on r440, not in the tunnel's sidecar.** The sidecar runs on
  all three nodes, so harmonia would have to listen on r440's LAN IP for
  all of them, i.e. for every pod (pod traffic to the LAN is masqueraded
  to the node IP), and the htpasswd would also be a Kubernetes Secret. On
  r440, harmonia listens only on the socket, and the secret is one file on
  the host that serves the store.
- **Reachability.** nginx's `:5080` has one consumer, the tunnel. The
  firewall (`cache.nix`) admits 5080 only from the nodes' LAN IPs and the
  VIP (the connectors connect from those, or over lo on r440). tailscale0
  is trusted on r440, so tailnet clients reach it too, with a password.
- **No shared caching.** harmonia marks NARs `Cache-Control:
  max-age=31536000`; nginx hides that and sends `private, no-store` on
  every response (401s included), so Cloudflare's edge never stores one.
  Never add a "Cache Everything" page rule or a Cache Rule covering
  `cache.neuros.is`.
- **Compression.** harmonia sends NARs uncompressed; nginx gzips them
  (level 1; about half the bytes for binaries). Nix decompresses
  transparently.
- **Streaming.** `proxy_buffering off`, `proxy_read_timeout 600s`; harmonia
  streams at once, so Cloudflare's 100 s time-to-first-byte limit is no
  problem. `access_log off`: thousands of `.narinfo` lookups on a slow HDD.
- **Failure.** After a failed query (unreachable, 5xx, or 401 from a
  missing or wrong netrc) Nix prints "disabling binary cache … for 60
  seconds" and carries on with cache.nixos.org (Nix's
  `HttpBinaryCacheStore::maybeDisable` does that only with `fallback` on);
  a NAR whose download fails is built instead (tested with a missing
  netrc).
- **Cloudflare.** NARs are large (the CUDA/torch closures are tens of GB)
  and go through the tunnel at r440's uplink speed. Cloudflare's terms
  forbid using the CDN for a disproportionate amount of large non-HTML
  content except through paid services built for it; this is private,
  low-volume use with nothing cached at the edge, but it is the kind of
  traffic those terms describe. Browser Integrity Check or Bot Fight Mode
  may challenge Nix's curl client: turn them off for `cache.neuros.is` if
  requests get 403/503 challenge pages.
- **Load on r440.** r440's root is the slow HDD that also holds etcd's
  WAL. Big NAR reads compete with etcd; watch etcd latency during large
  pulls ([cluster.md](cluster.md#etcd-health-check-any-member-in-bash)).

### Cost for c4130, and the direct path

Paths c4130 substitutes from r440 (the CUDA/torch/vLLM closures, tens of
GB) go c4130 → Cloudflare → r440 at internet speed, twice over the home
uplink, instead of over the 25G link. Paths built *for* c4130 on r440 are
still copied back over ssh/`bond0`, so this mostly hits closures r440
already holds but c4130 lacks (e.g. after a GC).

Until commit 6e02db6 ("c4130: substitute from cache.neuros.is; drop
harmonia's bond0 listener", 2026-11-12) c4130 substituted from harmonia on
`10.25.0.2:5000` over `bond0`. Reverting that commit restores harmonia's
TCP listener, the `bond0` port 5000 rule and c4130's direct substituter.

> **Unverified:** 6e02db6 predates the move of the netrc and signing key to
> sops (#37) and the firewall split; a plain `git revert` likely conflicts
> and would point back at `/var/lib/nix-cache/netrc`. Treat it as a guide,
> not a one-command rollback.

### GitHub Actions

`flake-check`, `eval-hosts` (checks.yml), `render`, `update` and
`pki-export-image` call the composite action `.github/actions/nix-cache`
and pass its output to install-nix-action's `extra_nix_config`:

```
extra-substituters = https://cache.neuros.is?priority=50   # after cache.nixos.org (40)
extra-trusted-public-keys = r440-cache-1:…                 # cluster/definition.nix binaryCache.publicKey
netrc-file = $RUNNER_TEMP/nix-cache.netrc                  # mode 600, from the secret
connect-timeout = 5
fallback = true
```

- **Secret `NIX_CACHE_NETRC`**: the `ci` user's netrc line. The action
  writes it with umask 077 and never prints it; GitHub masks it in logs.
- **Without the secret** (pull requests from forks, Dependabot) the action
  outputs nothing and the job runs on cache.nixos.org alone. A wrong or
  revoked password costs only a warning (401, cache disabled for 60 s).
- **Read-only.** CI cannot push to the cache. The checks only evaluate and
  render, so the gain is small (IFD and render inputs r440 happens to
  hold); `pki-export-image` builds a small image.
- Workflows of same-repo branches can read the secret, as with every
  Actions secret. It grants read access to r440's store, nothing else.
- The action hard-codes the URL and key; they mirror
  `cluster/definition.nix` `binaryCache`. Change both together.

### Adding or revoking a client

- **Revoke:** delete the user's line from `nix-cache-htpasswd`
  (`sops secrets/r440.yaml`), PR, switch r440. nginx reads the file per
  request. For CI, also delete the `NIX_CACHE_NETRC` secret.
- **Add:** make a password and htpasswd line as in step 3 below, add the
  line to `nix-cache-htpasswd`, put the netrc line in the client's
  `secrets/<host>.yaml` as `nix-cache-netrc`, set
  `custom.nixCache.enable = true` on the host, PR, switch r440 and then
  the client. Add a row to [secrets.md](secrets.md).
- **Check a client** (root on the host, run by the user):
  `sudo nix store info --store https://cache.neuros.is --option netrc-file /run/secrets/nix-cache-netrc`.

### Setting it up from scratch

The cache went live on 2026-11-12/13 (#36, then sops in #37). To rebuild
it, in this order; switch one host at a time and run the
[etcd health check](cluster.md#etcd-health-check-any-member-in-bash)
after each server.

1. Merge the change. Flux rolls the cloudflared pods (the route has no DNS
   yet, so nothing reaches it). No host uses the cache until it is
   switched.
2. **r440:** `git pull`, switch, `systemctl --failed`, the etcd check.
   nginx answers 500 until the htpasswd exists (step 3).
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
   (thousands of `.narinfo` lookups), and a 256-bit random password needs
   no slow hash.
4. **DNS** (admin on c4130, account cert `~admin/.cloudflared/cert.pem`):
   `cloudflared tunnel route dns --overwrite-dns 59a275ca-be31-4f8d-99ce-c536eaf490f8 cache.neuros.is`.
   Check: `curl -sI https://cache.neuros.is/nix-cache-info` → 401,
   `cache-control: private, no-store`, no `cf-cache-status: HIT`;
   `curl -s --netrc-file nix-cache-ci.netrc https://cache.neuros.is/nix-cache-info`
   → `StoreDir: /nix/store`. Optional, in the dashboard: a Cache Rule
   "Bypass cache" for hostname `cache.neuros.is`.
5. **GitHub secret** `NIX_CACHE_NETRC` = the content of
   `nix-cache-ci.netrc` (Settings → Secrets and variables → Actions, or
   `gh secret set NIX_CACHE_NETRC --repo charlie-horse/flake < nix-cache-ci.netrc`).
6. **Netrc** (c4130, m2mini, Famine): `sops secrets/<host>.yaml`, key
   `nix-cache-netrc`, value the host's line from `r440:~/nix-cache-<host>.netrc`
   (never on a command line). Until the host switches, Nix uses
   cache.nixos.org alone, with a warning.
7. **m2mini:** switch (with its `--override-input`), `systemctl --failed`,
   the etcd check, then the client check above.
8. **c4130:** GC first, outside the GPU window
   ([c4130.md](hosts/c4130.md)), switch, `systemctl --failed`, the etcd
   check, then the client check.
9. **Famine:** PR with its netrc (step 6), switch Famine.
10. On r440: `shred -u ~/nix-cache-*.pw ~/nix-cache-*.netrc`.
