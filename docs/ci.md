# CI

| Workflow | Runs on | Does |
| --- | --- | --- |
| `.github/workflows/checks.yml` | every PR and push to `main` | Checks only: the secrets guard, `nix flake check`, and an eval of each server's toplevel. Never builds or writes. |
| `.github/workflows/render.yml` | PRs and pushes to `main` that touch a render input | Renders `k8s/`. On `main` it also publishes the render to GHCR (a signed OCI artifact) and pings Flux. |
| `.github/workflows/update.yml` | Mon + Fri 04:00 UTC, or by hand | `nix flake update` (every input) → flake check + server evals + render → push `flake.lock` to `main`, then dispatch checks and render ([below](#updateyml)). |
| `.github/workflows/pki-export-image.yml` | PRs and pushes to `main` that touch `pkgs/pki-tools/**` or its other inputs | Builds `.#pki-export-image`; on `main` (push or dispatch) pushes it to GHCR ([below](#pki-export-imageyml)). |

Every job that runs Nix substitutes from r440's binary cache when the
secret is available ([below](#binary-cache)).

Every action is pinned by full commit SHA ([below](#pinned-actions)).

## checks.yml

| Job | Runner | What it does |
| --- | --- | --- |
| `secrets-guard` | ubuntu-24.04 | Fails if the diff adds a key file, a kubeconfig or a plaintext password ([details](#secrets-guard)). |
| `flake-check` | ubuntu-24.04 | `nix flake check --keep-going`: every output evaluates (every NixOS host: the desktop Famine and the servers c4130, r440 and m2mini; Famine's ISO; the packages). Its only `checks` output is `pki-tools` (`parts/packages.nix`; pytest in its checkPhase), the one thing flake check builds; nothing heavy. The k8s render is the system-independent output `k8s`, which flake check does not evaluate. |
| `format` | ubuntu-24.04 | `nix fmt -- --check` over every tracked `.nix` file (the flake's formatter, RFC-style nixfmt). Excluded: `hosts/Pestilence/servarr.nix` (any edit to it, reformatting included, trips the secrets guard). Run `nix fmt` before committing. |
| `eval-hosts` (matrix) | x86: ubuntu-24.04, m2mini: ubuntu-24.04-arm | `nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath` with import-from-derivation **disabled**, for c4130, r440 and m2mini. It checks `.system` and writes the drvPath to the job summary. |

`flake check` alone is not enough: it checks that each
`nixosConfigurations.*` evaluates to *a* configuration, but does not force
`toplevel.drvPath`. `eval-hosts` does.

On a pull request a newer push cancels the run in progress; on `main` every
push is checked.

### Eval only, never build the hosts

CI never builds a NixOS toplevel; builds happen on r440
([build-cache.md](build-cache.md)). The server evals pass `--option
allow-import-from-derivation false` (`$NO_IFD`), so evaluating them can
never turn into a build.

To compare a CI drvPath with what runs on a host, take the drvPath from the
job summary and, on the host:

```sh
nix-diff /run/current-system <drvPath>
```

`flake-check` cannot use `$NO_IFD`: the desktop hosts import from the store
copy of `./modules` (lib `mkHost`), which a fresh runner can only produce
with IFD allowed.

### m2mini (aarch64) and the vendor firmware

m2mini is evaluated on GitHub's native arm64 runner (`ubuntu-24.04-arm`).
Its configuration has no IFD, so it also evaluates
on x86_64. If the arm runner is unavailable, set `runner: ubuntu-24.04` on
its matrix entry.

Apple's peripheral firmware (`firmware.cpio`) is proprietary and never on a
runner. The flake's `m2mini-vendorfw` input defaults to the firmware-free
placeholder `hosts/m2mini/vendorfw`, so CI evaluates with
`hardware.asahi.extractPeripheralFirmware = false` (`hosts/m2mini/firmware.nix`).
On the box, deploy with `--override-input m2mini-vendorfw path:/boot/vendorfw`.

The `eval-hosts` step's env var `M2MINI_EVAL_FLAGS` (marked `HOOK(Max)`)
takes extra m2mini eval flags, e.g. an `--override-input`. It is empty: CI
uses the placeholder input.

### Secrets guard

The guard scans only the diff: the PR's merge-base to head, or on a push
`before..after` (falling back to `HEAD~1`). It fails on:

- **added or modified files whose basename** is `*-key.pem`, `*.key`,
  `kubeconfig`, `kubeconfig.*`, `*.kubeconfig`, `*-kubeconfig` or
  `*_kubeconfig` (`.nix` and `.md` files are exempt, so a module or doc
  *about* kubeconfigs can exist);
- **added lines** with a lowercase `password` followed by optional spaces and
  `=`, a PEM private-key header, or a kubeconfig client-key field. Lines
  starting with `#` or `//` are skipped, so comments and docs can name the
  pattern; `hashedPassword`/`hashedPasswordFile` never match (the match is
  case-sensitive);
- **sops files that are not fully encrypted**: every added or modified
  `secrets/*.yaml` and `k8s/**/*.sops.yaml` is checked as a whole (at the
  head commit, not just the diff). It needs a top-level `sops:` block with
  `mac: ENC[...]` and at least one recipient; every value outside that block
  must be `ENC[...]` and every comment `#ENC[...]`. A k8s file may have
  only the top-level keys `apiVersion kind metadata type data stringData
  sops` (the same set the render's `checkSecret` allows;
  [k8s/secrets.md](k8s/secrets.md)), the first four in the clear (Flux reads them), `data` and
  `stringData` encrypted. Any other file under `secrets/` (a subdirectory,
  a non-`.yaml` file) fails, as does any file under `k8s/secrets/` without
  the `.sops.yaml` suffix (the k8s render rejects those too).
  `secrets/pki/<node>.yaml` (host certs exported from cert-manager;
  no subdirectories) is the one exception to "every value
  encrypted": a top-level `<stem>.pem` may be plaintext if it holds
  nothing but `CERTIFICATE` blocks. Every `<stem>-key.pem` must be
  `ENC[...]`. The content checks (chain, node, completeness, expiry)
  are in the export job, `pkgs/pki-tools/pki/cli_export.py`. Recipients: `.sops.yaml`.

A second step checks **every** sops file in the tree, not only the diff: its age
recipients (`sops.age[].recipient`) must equal those of the first
`.sops.yaml` creation rule whose `path_regex` matches it, i.e. the file was
re-wrapped with `sops updatekeys` after the last recipient change. When
the rule sets `encrypted_regex` (`secrets/pki/`, `k8s/secrets/`), the
file's `sops.encrypted_regex` must be the same. It uses
only public keys and names missing/extra recipients by their `.sops.yaml`
anchor. The host side of the same question (can *this* host decrypt?) is
the pre-switch check `sopsDecrypt` in `modules/system/sops.nix`.

It prints only `file:line` (or file and key path), never the matching text.
Secrets in git are sops-encrypted only (sops-nix on the hosts:
`modules/system/sops.nix`), the cluster's host certs and CA keys included
(`secrets/pki/`, `k8s/secrets/cluster-pki/`; [pki.md](pki.md)). Every secret,
CI's included, is listed in [secrets.md](secrets.md).

The guard scans only the diff, so the plaintext credentials already in
`hosts/Pestilence` trip it only when those lines are edited.

## render.yml

```
render  (PR + main)   nix build .#k8s.manifests  (this commit)
                      -> no key material?  -> images multi-arch? (advisory)
                      -> upload the tree
publish (main only)   flux push artifact oci://ghcr.io/<repo>/manifests:<sha12>
                      flux tag … --tag main;  cosign sign (keyless)
                      POST Flux's Receiver (HMAC)  -> cluster fetches at once
                      save the build cache (lets identical inputs skip the build)
```

- **Triggers:** pushes and PRs touching `k8s/**`, `cluster/**`, `parts/**`,
  `flake.nix`, `flake.lock` or the workflow, i.e. everything the render
  reads. The cache key hashes the same set.
- **Every push to main publishes.** The cache (keyed on the same inputs)
  only skips the `nix build` when an earlier render had identical inputs; it
  never decides whether to publish. Republishing identical content is a
  no-op for Flux (same digest). Dispatching `render.yml` on `main`
  republishes the current render.
- **main only:** `publish` never runs for another ref, dispatches included.
  `components/flux/sync.nix` accepts only cosign signatures whose identity is
  `…/.github/workflows/render.yml@refs/heads/main`.
- **Permissions:** `render` is read-only; `publish` has `packages: write`
  (GHCR) and `id-token: write` (keyless signing), nothing else.
- **Secrets:** `NIX_CACHE_NETRC` (optional, shared by every workflow:
  r440's binary cache, [below](#binary-cache)), `FLUX_WEBHOOK_TOKEN` (the HMAC key, the same bytes as the
  cluster Secret `flux-system/webhook-token`, no trailing newline) and
  `FLUX_WEBHOOK_URL` (`https://<cluster.fluxWebhook.host>` plus the
  Receiver's `status.webhookPath`, which changes when the token does).
- **Concurrency:** PRs cancel older runs; on `main` runs queue, so artifacts
  are published in commit order.

The GHCR package `charlie-horse/flake/manifests` is public, so Flux pulls it
without credentials.

## update.yml

Mondays and Fridays at 04:00 UTC, or dispatched by
hand. Hands-free: no PR.

1. `nix flake update` updates **every** input, `vllm-fork` included.
   Nothing to do if no input moved.
2. Gates, the same a human change gets: `nix flake check --keep-going`, an
   eval of each server's toplevel drvPath (c4130, r440, m2mini, on x86_64,
   with `$NO_IFD` as in `eval-hosts`) and `nix build .#k8s.manifests`.
3. Only if all pass is the new `flake.lock` committed by
   `github-actions[bot]` and pushed to `main` (fast-forward; if `main`
   moved and touched `flake.nix`/`flake.lock` meanwhile, it gives up and the
   next run retries). Nothing is pushed on failure; the failed run is the
   signal (GitHub emails the repo owner).
4. A push made with `GITHUB_TOKEN` triggers no workflows, so the job then
   dispatches `checks.yml` and `render.yml` on `main`; render's `publish`
   ships the new render to Flux as for any push to `main`.

The commit message and the run summary list every changed input
(before/after rev) and **warn when `vllm-fork` moved**: that changes
c4130's production vLLM on its next switch (build it on r440, GC first;
[c4130.md](hosts/c4130.md)). Hosts
take the new inputs on their next `git pull && nixos-rebuild switch`.

Permissions: `contents: write` (push) and `actions: write` (dispatch). It
needs `main` to accept pushes from `github-actions[bot]` (no branch
protection against it, or the bot allowed to bypass).

## pki-export-image.yml

Builds `.#packages.x86_64-linux.pki-export-image` (the image of the
cert-manager → sops export job, `pkgs/pki-tools`) on PRs and pushes to
`main` that touch `pkgs/pki-tools/**`,
`k8s/components/infra/cluster-pki/leaves.nix`, `cluster/definition.nix`,
`parts/packages.nix`, `flake.lock` or the workflow. On `main` (push or
dispatch) it pushes the image to `ghcr.io/<repo>/pki-export` with tags
`<sha12>` and `main` (skopeo, `GITHUB_TOKEN`, `packages: write`) and writes
the digest to the job summary; pin it in
`k8s/components/infra/cluster-pki/export.nix`. Operations:
[pki.md](pki.md#export-job-image).

## Binary cache

`flake-check`, `eval-hosts`, `render`, `update` and `pki-export-image` add
r440's read-only binary cache (https://cache.neuros.is) through the local
composite action `.github/actions/nix-cache`, which turns the optional
secret `NIX_CACHE_NETRC` into nix.conf lines for install-nix-action's
`extra_nix_config`. Without the secret (fork PRs, Dependabot) the jobs run
on cache.nixos.org alone. What the action writes, the secret's format and
how to revoke it: [build-cache.md](build-cache.md#github-actions).

The action pins nothing external (it is a bash step), so it is not in the
table below.

## Pinned actions

Every action is pinned by full commit SHA, with the tag in a comment.

| Action | Tag | SHA |
| --- | --- | --- |
| actions/checkout | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| cachix/install-nix-action | v31.11.2 | `448cde739abec1eaf0646249e3d25bb8d9bc7702` |
| actions/upload-artifact | v7.0.2 | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |
| actions/download-artifact | v8.0.2 | `9000827ccba6bdab643e8b6fd33ac0654aef8333` |
| actions/cache (restore, save) | v5.1.0 | `caa296126883cff596d87d8935842f9db880ef25` |
| fluxcd/flux2/action | v2.9.5 | `dd233c4fadef306a62b7893204f8e3817fecc2b2` |
| sigstore/cosign-installer | v4.1.3 | `756fe2d284c7292c4e9b62c8a28f1e5629c59532` |

To bump one: `git ls-remote https://github.com/<owner>/<repo> refs/tags/<tag> 'refs/tags/<tag>^{}'`,
take the `^{}` line if there is one, then run actionlint.

## Running the same checks locally

```sh
nix shell nixpkgs#actionlint nixpkgs#shellcheck -c actionlint
nix flake check --keep-going
for h in c4130 r440 m2mini; do
  nix eval --raw --option allow-import-from-derivation false \
    ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath"; echo
done
nix build .#k8s.manifests                                     # the render
nix build .#k8s.checkImages && ./result/bin/k8s-check-images
```

New files must be `git add`ed before Nix can see them. On r440, Nix's git
fetcher fails on `catenix/kubernetes-src`; add
`--override-input catenix/kubernetes-src path:/tmp/k8s-src` after cloning
the `v1.37.0` tag there ([cluster.md](cluster.md#changing-something-in-the-cluster)).
