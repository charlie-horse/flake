# CI

`nix flake check` is the gate: a commit is good when it passes. The checks
are the flake's `checks` (`parts/checks.nix`); CI (`checks.yml`) only runs
`nix flake check`. Each workflow's header comment says what it does.

- Run `nix flake check` before every commit. The hook in `.githooks/` does
  it; enable it once per clone with `git config core.hooksPath .githooks`.
- A new check goes in `parts/checks.nix` as a flake check, never as a CI
  step. It must fetch only through fixed-output derivations and build
  nothing heavier than the k8s render.
- CI never builds a NixOS toplevel; builds happen on r440
  ([build-cache.md](build-cache.md)).
- `nix fmt` fixes what the `format` check reports.
- After changing recipients in `.sops.yaml`, run `sops updatekeys` on every
  file the rule matches, or the `sops` check fails.
- New files must be `git add`ed before Nix can see them.
- Pin every action by full commit SHA with the tag in a comment. To bump
  one: `git ls-remote https://github.com/<owner>/<repo> refs/tags/<tag> 'refs/tags/<tag>^{}'`,
  take the `^{}` line if there is one, then run actionlint.

## Running other checks locally

```sh
actionlint                                   # from nix develop
nix build .#k8s.checkImages && ./result/bin/k8s-check-images
```

To compare a host's config with what runs on it, on the host:
`nix-diff /run/current-system $(nix eval --raw /etc/nixos#nixosConfigurations.<host>.config.system.build.toplevel.drvPath)`.

## render.yml

- Every push to `main` publishes the render its `checks` run built;
  dispatching `render.yml` on `main` builds and republishes the current
  render. Flux accepts only artifacts signed by this
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
