# Docs

Every doc in this repo, and the one topic each owns. Edit a topic in its
home and link to it from elsewhere. The rules (where docs go, comment size,
updating docs with code) are the documentation policy in
[CLAUDE.md](../CLAUDE.md#documentation-policy); `scripts/check-docs.sh`
enforces them in CI.

## Cluster and operations

| Doc | Canonical for |
| --- | --- |
| [cluster.md](cluster.md) | The cluster runbook: what runs where, `cluster/definition.nix`, `modules/cluster`, apiserver VIP, changing a host, etcd health check, accounts, access from a cloud session, SSH between hosts, Tailscale |
| [secrets.md](secrets.md) | The registry of every secret and where it lives; add a row for any new one |
| [decisions.md](decisions.md) | Open decisions and unverified host state, collected from all docs |
| [build-cache.md](build-cache.md) | r440 as remote builder and binary cache (cache.neuros.is), client setup |
| [ci.md](ci.md) | GitHub Actions: checks, render, update, pki-export-image, running checks locally |

## Security

| Doc | Canonical for |
| --- | --- |
| [auth.md](auth.md) | Accounts, SSH client config, sops-nix on the hosts, `custom.auth` (sshd, sudo, console, hardware factor), desktop YubiKey |
| [pki.md](pki.md) | Cluster PKI: YubiKey root CA, intermediates, cert-manager issuers, host certs via sops, break-glass, CA rotation, ca-ceremony-tools |

## Hosts

| Doc | Canonical for |
| --- | --- |
| [hosts/c4130.md](hosts/c4130.md) | c4130: hardware, CUDA/Volta limits, deploying (GC first, GPU window), files on the host |
| [hosts/c4130-vllm.md](hosts/c4130-vllm.md) | vLLM, LMCache, Flint and custom models on c4130 |
| [hosts/r440.md](hosts/r440.md) | r440: memory limits, containers, firewall (builder and cache: build-cache.md) |
| [hosts/m2mini.md](hosts/m2mini.md) | m2mini: Asahi boot, vendor firmware, fish, XDG, neovim |
| [hosts/famine.md](hosts/famine.md) | Famine (workstation), including enrolling it in sops |
| [hosts/pestilence.md](hosts/pestilence.md) | Pestilence (archived) and how to restore it |

## Kubernetes (`k8s/`)

| Doc | Canonical for |
| --- | --- |
| [k8s/README.md](k8s/README.md) | Layout, components, flake output, render, Flux deployment, bootstrap, host-side assumptions |
| [k8s/secrets.md](k8s/secrets.md) | In-cluster sops Secrets: rotating, adding, the Flux bootstrap key |
| [k8s/apps.md](k8s/apps.md) | cert-manager, authentik, Headlamp, Cloudflare tunnel, Open WebUI |

## Proposals (not applied)

| Doc | About |
| --- | --- |
| [proposals/catenix-ci.md](proposals/catenix-ci.md) | CI for the catenix repo |

## History (not updated; the current docs win where they disagree)

| Doc | About |
| --- | --- |
| [history/cluster-handoff-2026-10.md](history/cluster-handoff-2026-10.md) | The October 2026 cluster cut-over |
| [history/charlie-removal-2026-11.md](history/charlie-removal-2026-11.md) | Moving the servers' login from charlie to admin |
| [history/pki-migration-plan-2026-11.md](history/pki-migration-plan-2026-11.md) | The PKI migration plan (P1–P9) and the legacy PKI inventory |
| [history/c4130-vllm-state-2026-10.md](history/c4130-vllm-state-2026-10.md) | c4130 vLLM snapshots and the pre-cutover fork |
