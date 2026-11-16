# flake: NixOS config for the neurosis cluster

This repo is the source of truth for the three NixOS 26.05 servers that run
the neurosis cluster (c4130, r440, m2mini), the workstation Famine, and the
in-cluster resources Flux deploys (`k8s/`). `AGENTS.md` is a symlink to this
file. Start at [docs/README.md](docs/README.md): it maps every topic to its
one canonical doc.

## Rules for working on the hosts

These are the rules most likely to cause damage if missed. Details live in
the linked docs; don't repeat them here.

- **SSH only when the user has allowed it for the task.** How to reach the
  hosts from a cloud session (userspace Tailscale, `TAIL_AUTH_KEY`, the
  `ProxyCommand`): [docs/cluster.md#access-from-a-cloud-session](docs/cluster.md#access-from-a-cloud-session).
  The login is `admin` (stage 2 of charlie's removal is in config for every
  server; [docs/cluster.md#accounts-on-the-servers](docs/cluster.md#accounts-on-the-servers)).
  m2mini's login shell is fish: wrap sh syntax in `bash -s <<'EOF' … EOF`.
- **The user runs `sudo`, not the cloud session.** Write privileged steps as
  copy-paste blocks and say which account runs them. The cloud session runs
  only read-only checks that need no sudo. It holds no sudo password, no
  YubiKey PIN and no cluster credentials.
- **Secrets never go in git or on a command line**, except sops-encrypted
  files in `secrets/` and `k8s/secrets/`. Every secret is listed in
  [docs/secrets.md](docs/secrets.md); add a row for any new one.
- **PKI:** never run `ykman piv reset` or touch PIV slot 82 of the admin
  YubiKey ([docs/pki.md](docs/pki.md)).
- **Deploying:** change on a branch, CI, merge; then on the host
  `cd /etc/nixos && git pull && sudo nixos-rebuild switch --flake /etc/nixos#<host>`
  (m2mini adds `--override-input m2mini-vendorfw path:/boot/vendorfw`).
  Never `nix flake update`, edit files, or `sudo git` inside `/etc/nixos`
  on a host. Switch one host at a time and run the etcd health check after
  each ([docs/cluster.md#changing-a-host](docs/cluster.md#changing-a-host)).
  Leave etcd alone unless the user asks.
- **c4130:** GC old generations before every switch, and switch outside the
  GPU window (22:00–05:55 America/New_York)
  ([docs/hosts/c4130.md#deploying-c4130](docs/hosts/c4130.md#deploying-c4130)).
  Builds happen on r440 only ([docs/build-cache.md](docs/build-cache.md)).
- **GPUs are Volta (sm_70):** CUDA 13 can't target them; anything that
  compiles or ships GPU kernels uses CUDA 12.x, and models run `--dtype half`
  ([docs/hosts/c4130-vllm.md](docs/hosts/c4130-vllm.md)).

## Documentation policy

Keep the docs in one place, one copy of each fact, and current.

1. **Where docs live.** Prose goes in `docs/`; [docs/README.md](docs/README.md)
   lists every doc and the topic it owns. Per-host docs are
   `docs/hosts/<host>.md`. Dated snapshots, completed plans and finished
   procedures go to `docs/history/` (named `<topic>-<yyyy-mm>.md`);
   unapplied proposals go to `docs/proposals/`. A directory may keep a
   `README.md` or `CLAUDE.md` of at most 15 lines that points into `docs/`.
2. **One canonical home per topic.** Before writing, find the topic's home in
   docs/README.md and edit it there. Elsewhere, link to it instead of
   restating it. A new topic gets a row in docs/README.md.
3. **Code comments stay short and local.** Explain why this line or option
   exists. A contiguous comment block is at most 15 lines; longer prose
   (procedures, rationale, history, tables) goes to the doc, with a one-line
   pointer in the code, e.g. `# Procedure: docs/build-cache.md#setting-it-up`.
4. **Update docs in the same PR as the code.** A change that makes a doc
   wrong fixes the doc. Moving or renaming a doc or heading fixes every link to
   it.
5. **State, not guesses.** Write the current state in the present tense.
   Something the repo can't prove (host state, whether a manual step was
   done) is marked `> **Unverified:** …`; an undecided choice is marked
   `> **Open decision:** …` and listed in [docs/decisions.md](docs/decisions.md).
   Don't resolve one silently. Don't record values that go stale (disk
   usage, what a host runs) without a date.
6. **Enforced by CI.** `scripts/check-docs.sh` (the `docs` job in
   `.github/workflows/checks.yml`) fails on comment blocks over 15 lines,
   broken relative links and anchors, references to missing `docs/…md` files, and docs
   not listed in docs/README.md. Run it locally before pushing. A deliberate
   exception goes in `.docs-allowlist` with a comment saying why.
