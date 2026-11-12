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

  resources."source.toolkit.fluxcd.io".v1.GitRepository.${name} = {
    metadata.namespace = namespace;
    spec = {
      url = "https://github.com/charlie-horse/flake/manifests";
      ref.branch = "main";
      interval = "5m";
      # Only what the Kustomization reads (gitignore syntax: a parent
      # directory must be re-included before its children).
      ignore = ''
        /*
        !/k8s/
        /k8s/*
        !/k8s/rendered/
      '';
    };
  };

  resources."source.toolkit.fluxcd.io".v1.OCIRepository.${name} = {
    metadata.namespace = namespace;
    spec = {
      url = "oci://ghcr.io/charlie-horse/manifests";
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
