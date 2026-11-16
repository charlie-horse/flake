# Open decisions and unverified state

Collected from the docs during the 2026-11-16 consolidation. Each item also
sits, flagged, in the doc that owns the topic. When one is settled, fix that
doc and delete the line here.

## Open decisions

| Decision | Where it's flagged |
| --- | --- |
| Where does cluster state live? The project plan says catenix; today it is `k8s/` in this repo, and catenix is only the render library. (Flux already pulls a cosign-signed OCI artifact, i.e. gitless.) | [k8s/README.md](k8s/README.md) |
| Apply the catenix CI proposal (needs push access to catenix); has catenix gained its own CI since? | [proposals/catenix-ci.md](proposals/catenix-ci.md) |
| Does `main`'s branch protection allow pushes by `github-actions[bot]`? `update.yml` (PR #55) needs it to push `flake.lock`. | [ci.md](ci.md) |
| Drop the host-side Flint args once vllm-sm70 #36 lands (`TODO(cutover)` in `hosts/c4130/vllm/default.nix`). | [hosts/c4130-vllm.md](hosts/c4130-vllm.md) |
| Does r440 still need `virtualisation.containers` (charlie's rootless podman), and what happens to `/home/charlie/flint-swebench` (68 GB)? | [hosts/r440.md](hosts/r440.md) |
| Keep the m2mini input that has `TODO: drop if Gus stops using it` in `flake.nix`? | [hosts/m2mini.md](hosts/m2mini.md) |
| The hardware factor (`custom.auth`) can't be enabled: `admin.nix` has one `sk-` key and two are required. | [auth.md](auth.md) |
| PKI follow-ups: sign-only mode for `ca-ceremony`, leaf-expiry monitoring, a reminder for the workload intermediate renewal (expires 2028-11-12), optional trust-manager Bundle. | [pki.md](pki.md) |
| Famine's sops enrolment (steps 1–6) is not done; Famine is not a recipient in `.sops.yaml`. | [hosts/famine.md](hosts/famine.md) |

## Unverified host state

The repo can't prove these; check on the host and update the owning doc.

| Unverified | Where it's flagged |
| --- | --- |
| Each server has switched to its stage-2 generation (admin only, charlie gone); `/home/charlie`, `r440:/var/backups/charlie-home/`, m2mini's `/var/lib/secrets/charlie.passwd` and charlie in the tailnet SSH policy are removed. | [cluster.md](cluster.md#accounts-on-the-servers), [history/charlie-removal-2026-11.md](history/charlie-removal-2026-11.md) |
| The old PKI directory on r440 and the old leaves on each node were shredded after P9 (#54). | [cluster.md](cluster.md), [pki.md](pki.md) |
| The pre-sops and setup files for the binary cache were shredded (setup files are listed both at `/root/nix-cache-setup` and `~/nix-cache-*`). | [build-cache.md](build-cache.md), [secrets.md](secrets.md) |
| The `svc:kube-api` Tailscale Service rollout is complete on all three hosts, and whether `tailscale serve set-config --all` replaces other Services config. | [cluster.md](cluster.md#tailscale) |
| c4130: root disk use (41% on 2026-11-05, 60% on 2026-11-12), driver 580, vllm-sm70's CUDA 12.6 / torch 2.14, the LMCache heartbeat fix (vllm-sm70 PR #10) deployed, `/var/lib/vllm/models` still empty, Open WebUI reads Flint's `reasoning` field. | [hosts/c4130.md](hosts/c4130.md), [hosts/c4130-vllm.md](hosts/c4130-vllm.md) |
| vLLM/LMCache module internals (connector config, per-model defaults) were documented against the old fork and not re-checked in vllm-sm70. | [hosts/c4130-vllm.md](hosts/c4130-vllm.md) |
| Which physical keys the three u2f credentials belong to. | [auth.md](auth.md) |
| Where Famine's checkout lives and whether it tracks main. | [hosts/famine.md](hosts/famine.md) |

## Possible bugs noticed (code unchanged)

- `hosts/m2mini/neovim/customPlugins.nix`: the deadcolumn hash ends in `=e`, a stray character after the base64 padding; it may fail the m2mini build.
