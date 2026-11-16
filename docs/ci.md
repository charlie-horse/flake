# CI

The workflows are `.github/workflows/*.yml`; each one's header comment says
what it does. Rules and procedures the YAML can't state:

- CI never builds a NixOS toplevel; builds happen on r440
  ([build-cache.md](build-cache.md)). Server evals keep
  `--option allow-import-from-derivation false` (`$NO_IFD`) so an eval can
  never turn into a build.
- Run `nix fmt` before committing (`format` runs `nix fmt -- --check`).
- New files must be `git add`ed before Nix can see them.
- Pin every action by full commit SHA with the tag in a comment. To bump
  one: `git ls-remote https://github.com/<owner>/<repo> refs/tags/<tag> 'refs/tags/<tag>^{}'`,
  take the `^{}` line if there is one, then run actionlint.
- If GitHub's arm runner is unavailable, set `runner: ubuntu-24.04` on
  m2mini's `eval-hosts` matrix entry (its config evaluates on x86_64 too).

## Running the checks locally

```sh
nix shell nixpkgs#actionlint nixpkgs#shellcheck -c actionlint
nix fmt -- --check $(git ls-files '*.nix' | grep -v '^hosts/Pestilence/servarr.nix$')
nix flake check --keep-going
for h in c4130 r440 m2mini; do
  nix eval --raw --option allow-import-from-derivation false \
    ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath"; echo
done
nix build .#k8s.manifests                                     # the render
nix build .#k8s.checkImages && ./result/bin/k8s-check-images
```

On r440, Nix's git fetcher fails on `catenix/kubernetes-src`; add
`--override-input catenix/kubernetes-src path:/tmp/k8s-src` after cloning
the `v1.37.0` tag there ([cluster.md](cluster.md#changing-something-in-the-cluster)).

To compare a CI drvPath (from the `eval-hosts` job summary) with what runs
on a host, on the host: `nix-diff /run/current-system <drvPath>`.

## Secrets guard

Checks that every changed sops file is fully encrypted, and that every sops
file in the tree is encrypted to its `.sops.yaml` recipients. After changing
recipients in `.sops.yaml`, run `sops updatekeys` on every file the rule
matches. It does not scan for plaintext secrets; never commit them.

## render.yml

- Every push to `main` publishes; dispatching `render.yml` on `main`
  republishes the current render. Flux accepts only artifacts signed by this
  workflow on `main`.
- Secrets: `FLUX_WEBHOOK_TOKEN` must be the same bytes as the cluster
  Secret `flux-system/webhook-token`, no trailing newline.
  `FLUX_WEBHOOK_URL` is `https://<cluster.fluxWebhook.host>` plus the
  Receiver's `status.webhookPath`; update it whenever the token changes.
- The GHCR package `manifests` must stay public (Flux pulls it without
  credentials).

## update.yml

- `main` must accept pushes from `github-actions[bot]`.
- A failed run pushes nothing; the failed run is the signal.
- When the run warns that `vllm-fork` moved, c4130's next switch changes
  production vLLM: build it on r440 and GC c4130 first
  ([c4130.md](hosts/c4130.md)).

## pki-export-image.yml

On `main` it pushes the image and writes its digest to the job summary; pin
that digest in `k8s/components/infra/cluster-pki/export.nix`
([pki.md](pki.md#export-job-image)).

Jobs use r440's binary cache through `.github/actions/nix-cache`
([build-cache.md](build-cache.md#github-actions)).
