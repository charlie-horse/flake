# k8s/ — in-cluster resources (catenix)

Every object in the cluster that is not a NixOS service is declared here as
a catenix module, rendered by `nix build .#k8s.manifests`, published by CI as
a signed OCI artifact and applied by Flux.

Docs (canonical, in `docs/k8s/`):

- [README.md](../docs/k8s/README.md): layout, components, flake output,
  render, deployment, deferred components, bootstrap, host assumptions
- [secrets.md](../docs/k8s/secrets.md): the sops-encrypted Secrets in
  `secrets/` (rotation, adding one, the bootstrap key)
- [apps.md](../docs/k8s/apps.md): cert-manager, authentik, Headlamp, the
  Cloudflare tunnel, Open WebUI
