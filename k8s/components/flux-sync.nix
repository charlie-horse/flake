# What Flux reconciles: the signed OCI artifact CI pushes on every merge
# to main (.github/workflows/k8s.yml, job publish-oci):
# oci://ghcr.io/charlie-horse/flake-manifests, tag `main`. It holds the
# tree this directory renders, Flux itself (40-flux-system) and these two
# objects included, so Flux keeps itself up to date and prunes what is
# removed. Public package: no secretRef. Cosign keyless signatures are
# verified against the k8s.yml workflow on refs/heads/main.
#
# Rollback/pin: set `ref.tag = "sha-<commit>"` (or `ref.digest`).
#
# Typed by the flux2 chart's CRDs (the same chart as 40-flux-system;
# only its CRDs are read here, nothing of it is rendered).
{
  lib,
  pkgs,
  catenix,
  charts,
  kubeVersion,
  ...
}:
let
  namespace = "flux-system";
  name = "flux-system";

  chartCrds = lib.filter (m: (m.kind or null) == "CustomResourceDefinition") (
    builtins.fromJSON (
      builtins.readFile (
        catenix.helmTemplate pkgs {
          chart = charts.flux2;
          release = {
            name = "flux2";
            inherit namespace;
          };
          inherit kubeVersion;
        }
      )
    )
  );
in
{
  imports = [ (catenix.crdModule chartCrds) ];

  validation.strict = true;

  resources."source.toolkit.fluxcd.io".v1.OCIRepository.${name} = {
    metadata = { inherit namespace; };
    spec = {
      url = "oci://ghcr.io/charlie-horse/flake-manifests";
      ref.tag = "main";
      interval = "5m";
      verify = {
        provider = "cosign";
        # Keyless: only artifacts signed by this repo's k8s workflow on main.
        matchOIDCIdentity = [
          {
            issuer = "^https://token\\.actions\\.githubusercontent\\.com$";
            subject = "^https://github\\.com/charlie-horse/flake/\\.github/workflows/k8s\\.yml@refs/heads/main$";
          }
        ];
      };
    };
  };

  resources."kustomize.toolkit.fluxcd.io".v1.Kustomization.${name} = {
    metadata = { inherit namespace; };
    spec = {
      sourceRef = {
        kind = "OCIRepository";
        inherit name;
      };
      # The artifact root is the render itself.
      path = "./";
      interval = "10m";
      retryInterval = "2m";
      timeout = "5m";
      prune = true;
      wait = false;
    };
  };
}
