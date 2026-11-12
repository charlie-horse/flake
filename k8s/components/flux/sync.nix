# What Flux reconciles: the render of k8s/ as an OCI artifact on GHCR,
# pushed and cosign-signed (keyless) by .github/workflows/render.yml on
# main. Only artifacts signed by that workflow on main are applied.
#
# The OCIRepository polls daily; pushes arrive at once via the Receiver
# (receiver.nix). The Kustomization re-applies every 10 minutes, which also
# corrects drift.
{ ... }:
let
  namespace = "flux-system";
in
{
  resources."source.toolkit.fluxcd.io".v1.OCIRepository.flux-system-oci = {
    metadata = { inherit namespace; };
    spec = {
      url = "oci://ghcr.io/charlie-horse/flake/manifests";
      ref.tag = "main";
      interval = "24h";
      verify = {
        provider = "cosign";
        matchOIDCIdentity = [
          {
            issuer = "^https://token\\.actions\\.githubusercontent\\.com$";
            subject = "^https://github\\.com/charlie-horse/flake/\\.github/workflows/render\\.yml@refs/heads/main$";
          }
        ];
      };
    };
  };

  resources."kustomize.toolkit.fluxcd.io".v1.Kustomization.flux-system = {
    metadata = { inherit namespace; };
    spec = {
      sourceRef = {
        kind = "OCIRepository";
        name = "flux-system-oci";
      };
      path = "./";
      interval = "10m";
      retryInterval = "2m";
      timeout = "5m";
      prune = true;
      wait = false;
    };
  };
}
