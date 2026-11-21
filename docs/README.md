# Docs

Procedures and rules for operating what the flake declares. What runs where
and how it is configured: read the Nix source. Rules for these docs:
[CLAUDE.md](../CLAUDE.md#documentation-policy).

Tools: `nix develop` (or direnv with `.envrc`) has every tool these
procedures use, except the root-CA tools in `ca-ceremony-tools`
([pki.md](pki.md)). On a host, use the `nix shell` lines given.

| Doc | Procedures for |
| --- | --- |
| [cluster.md](cluster.md) | Changing a host, etcd health check, changing something in the cluster, Kubernetes API access, Tailscale |
| [secrets.md](secrets.md) | Where each secret lives and how to change it |
| [build-cache.md](build-cache.md) | r440 remote builder and binary cache: setup, adding and revoking a client |
| [ci.md](ci.md) | `nix flake check` as the gate, the pre-commit hook, CI rules |
| [auth.md](auth.md) | sops-nix on the hosts, `custom.auth` (registering keys, enabling the factor, lockout recovery), desktop YubiKey |
| [pki.md](pki.md) | Cluster PKI: renewal, break-glass, offline signing, CA rotation, export job |
| [hosts/c4130.md](hosts/c4130.md) | Deploying c4130 |
| [hosts/c4130-vllm.md](hosts/c4130-vllm.md) | vLLM rules, running a custom model, bumping vllm-fork, kill switches |
| [hosts/c4130-spindle.md](hosts/c4130-spindle.md) | Tangled spindle (CI runner): signing key, going live, allow-list |
| [hosts/m2mini.md](hosts/m2mini.md) | Deploying m2mini, vendor firmware |
| [hosts/famine.md](hosts/famine.md) | Deploying Famine, YubiKey, enrolling it in sops |
| [k8s/README.md](k8s/README.md) | Render, deployment, bootstrapping a fresh cluster |
| [k8s/secrets.md](k8s/secrets.md) | In-cluster sops Secrets: rotating, adding, the Flux bootstrap key |
| [k8s/apps.md](k8s/apps.md) | cert-manager, authentik, Headlamp, Cloudflare tunnel, Open WebUI, ATProto services (Tranquil PDS, Tangled knot, ATCR), LLDAP |
