# In-cluster resources, rendered with catenix (github:charlie-horse/catenix):
# every object Flux puts in the cluster is declared under ./components as a
# catenix module, type-checked with `validation.strict`.
#
# This file is the registry: which components exist, the cluster values and
# the Kubernetes version. { inputs, pkgs, lib } -> { manifests, components };
# the mechanics are ./render.nix, the shared helpers ./lib.nix.
# Exposed as the flake output `k8s` (parts/k8s.nix); deployed by
# .github/workflows/render.yml (signed OCI artifact on GHCR, Flux webhook).
#
# Overview, render layout, deployment: docs/k8s/README.md
{
  inputs,
  pkgs,
  lib,
}:
let
  definition = import ../cluster/definition.nix;
  # cluster/definition.nix is pure data; accept a { lib }: function too.
  cluster = if lib.isFunction definition then definition { inherit lib; } else definition;

  # Kubernetes version the charts are rendered for (`helm template
  # --kube-version`): the (26.05) nixpkgs `kubernetes` package the nodes run.
  kubeVersion = "v1.36.3";

  # Component -> module (a file, or a directory with default.nix). The
  # name is also the component's directory in the render. Flux applies the
  # whole tree (but `deferred`, below) as one Kustomization and orders
  # namespaces and CRDs first by itself; for a manual bootstrap the order is
  # infra/*, then flux, then apps/* (docs/k8s/README.md#bootstrap-fresh-cluster). Adding a component is
  # one line here (or in `deferred.modules`); ./render.nix needs no change.
  components = {
    "infra/runtime-classes" = ./components/infra/runtime-classes.nix;
    "infra/rbac" = ./components/infra/rbac.nix;
    "infra/local-storage" = ./components/infra/local-storage.nix;
    "infra/flannel" = ./components/infra/flannel.nix;
    "infra/coredns" = ./components/infra/coredns.nix;
    "infra/nvidia-device-plugin" = ./components/infra/nvidia-device-plugin.nix;
    "infra/cert-manager" = ./components/infra/cert-manager;
    "infra/cluster-pki" = ./components/infra/cluster-pki;
    "infra/cloudnative-pg" = ./components/infra/cloudnative-pg.nix;
    "flux" = ./components/flux;
    "apps/cloudflared" = ./components/apps/cloudflared;
    "apps/authentik" = ./components/apps/authentik;
    "apps/headlamp" = ./components/apps/headlamp.nix;
    "apps/open-webui" = ./components/apps/open-webui.nix;
  };

  # Deferred components: rendered under <dir>/<component>/ and applied by a
  # Flux Kustomization of their own (components/flux/stages.nix, named after
  # the component's last path element) once `flux-system` has applied the
  # same revision. <dir>/kustomization.yaml lists no resources, which keeps
  # `flux-system` (path ./) out of the subtree. For objects whose apply
  # needs a webhook that `flux-system` deploys: cert-manager's validates
  # every cert-manager.io object (failurePolicy Fail), and in `flux-system` a
  # down webhook would fail the apply of the whole cluster.
  deferred = {
    dir = "deferred";
    modules = {
      "infra/cert-manager-issuers" = ./components/infra/cert-manager/issuers.nix;
      "infra/cluster-pki-issuers" = ./components/infra/cluster-pki/issuers.nix;
    };
    # sops-encrypted Secrets: every ./secrets/<namespace>/<name>.sops.yaml
    # is copied verbatim (never parsed or re-serialised: that would break
    # the sops MAC) to <dir>/<name>/<namespace>/<name>.sops.yaml and applied
    # by the Kustomization `<name>`, which decrypts them with the age key
    # in flux-system/sops-age (components/flux/secrets.nix,
    # docs/k8s/secrets.md).
    secrets = {
      name = "secrets";
      src = ./secrets;
    };
  };
in
import ./render.nix {
  inherit
    inputs
    pkgs
    lib
    cluster
    kubeVersion
    components
    deferred
    ;
}
