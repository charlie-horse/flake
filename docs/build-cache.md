# Remote builder and binary cache (r440)

r440 is a **remote builder** for c4130 (c4130's Nix sends builds to it
over SSH: `hosts/r440/builder.nix`, `hosts/c4130/builder.nix`) and serves
its Nix store as a **binary cache** (a server other machines download
finished builds from: `hosts/r440/cache.nix`; clients: `custom.nixCache`;
host name and port: `cluster/definition.nix` `binaryCache`). The secrets
are listed in [secrets.md](secrets.md).

## Remote builder

- Keep `builderMaxJobs` in `hosts/r440/builder.nix` equal to `maxJobs` in
  `hosts/c4130/builder.nix`, and `max-jobs × cores` on r440 at 16: more
  than 16 nvcc jobs in total exhaust r440's RAM. A build that hits
  nix-daemon's memory cap fails with an OOM kill; retry it.
- **r440 down:** build on c4130 with `--option max-jobs 4` and expect the
  RAM use.
- Check from c4130: `sudo nix store ping --store ssh-ng://nixremote@<r440>`,
  with `<r440>` the address in `hosts/c4130/builder.nix`.

## Binary cache

- Substituters are ordered by `?priority=` (lower first): public caches
  first, r440's cache last. A new public cache gets a priority below
  `custom.nixCache.priority`, never equal to it.
- Every host that builds or runs CUDA code, r440 included, sets
  `custom.nixCache.cuda.enable`.
- Never add a Cloudflare "Cache Everything" page rule or a Cache Rule
  covering the cache host.
- If requests get 403/503 challenge pages, turn off Browser Integrity Check
  and Bot Fight Mode for the cache host.
- r440's root disk also holds etcd's WAL: watch etcd latency during large
  pulls ([cluster.md](cluster.md#etcd-health-check-any-member-in-bash)).
- A missing or wrong netrc costs only a warning: Nix disables the cache for
  60 s and falls back to cache.nixos.org.

### GitHub Actions

The workflows use `.github/actions/nix-cache`, fed by the Actions secret
`NIX_CACHE_NETRC` (the `ci` user's netrc line). The action hard-codes the
URL and key: change them together with `cluster/definition.nix`
`binaryCache`.

### Adding or revoking a client

A netrc (the file Nix reads the cache login from) is one line,
`machine <cache host> login <user> password <pw>`; `<cache host>` is
`binaryCache.host` in `cluster/definition.nix`.

- **Revoke:** delete the user's line from `nix-cache-htpasswd`
  (`sops secrets/r440.yaml`), PR, switch r440. For CI, also delete the
  `NIX_CACHE_NETRC` secret.
- **Add:** make a password and htpasswd line as in step 3 below, add the
  line to `nix-cache-htpasswd`, put the netrc line in the client's
  `secrets/<host>.yaml` as `nix-cache-netrc`, set
  `custom.nixCache.enable = true` on the host, PR, switch r440 and then
  the client. Add a row to [secrets.md](secrets.md).
- **Check a client:**
  `sudo nix store info --store https://cache.neuros.is --option netrc-file /run/secrets/nix-cache-netrc`.

### Setting it up

To set up the cache from scratch, in this order; switch one host at a time and run the
[etcd health check](cluster.md#etcd-health-check-any-member-in-bash)
after each server.

1. Merge the config that enables the cache. Flux (the in-cluster
   deployer) rolls the cloudflared pods. No host uses the
   cache until it is switched.
2. **r440:** `git pull`, switch, `systemctl --failed`, the etcd check.
   nginx answers 500 until the htpasswd exists (step 3).
3. **htpasswd on r440** (one random password per client; typed nowhere,
   never on a command line). Use SHA-512 crypt, not bcrypt: nginx checks
   the password on every request.

   ```sh
   lan="$(nix eval --raw -f /etc/nixos/cluster/definition.nix nodes.r440.lanIP):$(nix eval -f /etc/nixos/cluster/definition.nix binaryCache.port)"
   cd ~ && umask 077
   users="ci famine c4130 m2mini"
   for u in $users; do openssl rand -hex 32 > "nix-cache-$u.pw"; done
   for u in $users; do printf '%s:' "$u"; openssl passwd -6 -stdin < "nix-cache-$u.pw"; done \
     > nix-cache.htpasswd   # becomes `nix-cache-htpasswd` in secrets/r440.yaml (sops)
   for u in $users; do
     { printf 'machine cache.neuros.is login %s password ' "$u"; cat "nix-cache-$u.pw"; } > "nix-cache-$u.netrc"
   done
   sed "s/cache.neuros.is/${lan%:*}/" nix-cache-ci.netrc > lan-check.netrc
   curl -s -o /dev/null -w '%{http_code}\n' "http://$lan/nix-cache-info"                # 401
   curl -s --netrc-file lan-check.netrc "http://$lan/nix-cache-info" | head -1   # StoreDir: /nix/store
   rm lan-check.netrc
   ```

4. **DNS** (admin on c4130, account cert `~admin/.cloudflared/cert.pem`):
   `cloudflared tunnel route dns --overwrite-dns "$(nix eval --raw -f /etc/nixos/cluster/definition.nix tunnel.id)" cache.neuros.is`.
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
   (never on a command line).
7. **m2mini:** switch (with its `--override-input`), `systemctl --failed`,
   the etcd check, then the client check above.
8. **c4130:** GC first ([c4130.md](hosts/c4130.md)), switch, `systemctl --failed`, the etcd
   check, then the client check.
9. **Famine:** PR with its netrc (step 6), switch Famine.
10. On r440: `shred -u ~/nix-cache-*.pw ~/nix-cache-*.netrc`.
