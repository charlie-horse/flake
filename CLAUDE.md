# flake: NixOS config for the neurosis cluster

NixOS 26.05 servers c4130, r440 and m2mini (one Kubernetes cluster), the
workstation Famine, and the in-cluster resources Flux deploys (`k8s/`).
`AGENTS.md` is a symlink to this file. How everything works:
[docs/README.md](docs/README.md). Changing a host:
[docs/cluster.md#changing-a-host](docs/cluster.md#changing-a-host).

## Access

- SSH to the hosts only when the user has allowed it for the task.
- **Tailscale in a cloud session.** Download the static
  `tailscale_<ver>_amd64.tgz` from pkgs.tailscale.com (piping the install
  script into `sh` is blocked). Run in the background
  `tailscaled --tun=userspace-networking --statedir=/var/lib/tailscale --socket=/var/run/tailscale/tailscaled.sock`,
  then `tailscale up --authkey="$TAIL_AUTH_KEY" --hostname=flake-cloud --accept-routes`.
  If `tailscale status` shows no peers, run `up` again.
- **SSH** (Tailscale SSH; the tailnet policy permits `admin`): install
  `openssh-client`, then
  `ssh -o ProxyCommand="tailscale --socket=/var/run/tailscale/tailscaled.sock nc %h %p" admin@<host>`.
  MagicDNS resolves the bare names (tailnet `leaffish-monster.ts.net`).
  `admin` is the only login on the servers; root is locked.
- **m2mini's login shell is fish.** Run sh syntax as
  `ssh … admin@m2mini bash -s <<'EOF' … EOF` (give `</dev/null` to commands
  that read stdin) or interactively with `ssh -t … bash`.
- **Between hosts:** `ssh <host>` as admin with the `ssh:admin` FIDO2 key
  (YubiKey 19830800) from a forwarded agent; by LAN IP when Tailscale is
  down (`ssh -A admin@10.0.0.95`). Client setup: [docs/auth.md](docs/auth.md).
- **sudo is run by the user, not the cloud session.** Write privileged steps
  as copy-paste blocks for the user to run as `admin`. The cloud session holds
  only `TAIL_AUTH_KEY`: no sudo password, no YubiKey PIN, no cluster
  credentials. admin's password is in sops (`secrets/common.yaml`,
  `admin-password`).
- In `/etc/nixos` (owned by admin), `git pull` and `nixos-rebuild build` need
  no sudo; `nixos-rebuild switch`, `journalctl -u <unit>` and
  `systemctl stop/restart` do. Never `sudo git`, edit files or
  `nix flake update` there.
- Over SSH, `pgrep -f` matches its own command line; use
  `ps -ef | grep '[x]yz'`.
- Secrets never go in git or on a command line, except sops-encrypted files
  in `secrets/` and `k8s/secrets/`. Every secret is listed in
  [docs/secrets.md](docs/secrets.md).
- Never run `ykman piv reset` or touch PIV slot 82 of the admin YubiKey
  ([docs/pki.md](docs/pki.md)).

## Documentation policy

1. **Docs say how things work now.** No history, dates of past events,
   rationale ("why"), plans, decisions, open questions or status notes.
   Present tense, terse. A constraint you must follow is written as a rule.
2. **Tasks live in the project, not in git.** No TODO/FIXME/XXX, follow-ups
   or "later" notes in code or docs.
3. **Where docs live.** Prose goes in `docs/`; [docs/README.md](docs/README.md)
   lists every doc and the topic it owns. Per-host docs are
   `docs/hosts/<host>.md`. Access lives only in this file. A directory may
   keep a `README.md` or `CLAUDE.md` of at most 15 lines that points into
   `docs/`.
4. **One home per topic.** Edit a topic in its doc and link to it elsewhere.
   A new topic gets a row in docs/README.md.
5. **Code comments stay short and local.** At most 15 contiguous comment
   lines; longer prose goes to the doc, with a one-line pointer in the code.
6. **Docs change in the same PR as the code.** Moving or renaming a doc or
   heading fixes every link to it.
