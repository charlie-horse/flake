# What Flux reconciles: this repository over public HTTPS (no deploy key,
# no secretRef), branch main, path ./k8s/rendered: the tree this directory
# renders, which includes Flux itself (40-flux-system) and these two
# objects, so Flux keeps itself up to date and prunes what is removed.
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

  resources."source.toolkit.fluxcd.io".v1.OCIRepository.${name}-oci = {
    metadata.namespace = namespace;
    spec = {
      url = "oci://ghcr.io/charlie-horse/flake/manifests";
      ref.tag = "main";
      interval = "1m";
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

  resources."notification.toolkit.fluxcd.io".v1.Receiver.ghcr = {
    metadata = { inherit namespace; };
    spec = {
      type = "generic-hmac";
      secretRef.name = "webhook-token";   # made by hand, never in git
      resources = [
        { apiVersion = "source.toolkit.fluxcd.io/v1"; kind = "OCIRepository"; name = "flux-system-oci"; }
      ];
    };
  };

  resources."kustomize.toolkit.fluxcd.io".v1.Kustomization.${name} = {
    metadata.namespace = namespace;
    spec = {
      sourceRef = {
        kind = "OCIRepository";
        inherit name;
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
