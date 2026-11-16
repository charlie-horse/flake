# Docs

Every doc in this repo and the one topic each owns. Docs say how things
work now. Rules: [CLAUDE.md](../CLAUDE.md#documentation-policy).

## Cluster and operations

| Doc | Canonical for |
| --- | --- |
| [cluster.md](cluster.md) | The cluster runbook: what runs where, `cluster/definition.nix`, `modules/cluster`, apiserver VIP, changing a host, etcd health check, Tailscale |
| [secrets.md](secrets.md) | The registry of every secret and where it lives; add a row for any new one |
| [build-cache.md](build-cache.md) | r440 as remote builder and binary cache (cache.neuros.is), client setup |
| [ci.md](ci.md) | GitHub Actions: checks, render, update, pki-export-image, running checks locally |

## Security

| Doc | Canonical for |
| --- | --- |
| [auth.md](auth.md) | sops-nix on the hosts, `custom.auth` (sshd, sudo, console, hardware factor), desktop YubiKey |
| [pki.md](pki.md) | Cluster PKI: YubiKey root CA, intermediates, cert-manager issuers, host certs via sops, break-glass, CA rotation, ca-ceremony-tools |

## Hosts

| Doc | Canonical for |
| --- | --- |
| [hosts/c4130.md](hosts/c4130.md) | c4130: hardware, CUDA/Volta limits, deploying (GC first), files on the host |
| [hosts/c4130-vllm.md](hosts/c4130-vllm.md) | vLLM, LMCache, Flint and custom models on c4130 |
| [hosts/r440.md](hosts/r440.md) | r440: memory limits, containers, firewall (builder and cache: build-cache.md) |
| [hosts/m2mini.md](hosts/m2mini.md) | m2mini: Asahi boot, vendor firmware, fish, XDG, neovim |
| [hosts/famine.md](hosts/famine.md) | Famine (workstation), including enrolling it in sops |

## Kubernetes (`k8s/`)

| Doc | Canonical for |
| --- | --- |
| [k8s/README.md](k8s/README.md) | Layout, components, flake output, render, Flux deployment, bootstrap, host-side assumptions |
| [k8s/secrets.md](k8s/secrets.md) | In-cluster sops Secrets: rotating, adding, the Flux bootstrap key |
| [k8s/apps.md](k8s/apps.md) | cert-manager, authentik, Headlamp, Cloudflare tunnel, Open WebUI |
