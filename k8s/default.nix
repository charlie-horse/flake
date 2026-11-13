# In-cluster resources, rendered with catenix
# (github:charlie-horse/catenix): every object Flux puts in the cluster is
# declared under ./components as a catenix module
# (`resources.<group|core>.<version>.<Kind>.<name>`), type-checked against
# the Kubernetes API (catenix's pinned v1.37 spec) and the CRDs of the charts
# it imports, with `validation.strict` on.
#
# A function of { inputs, pkgs, lib } returning
#
#   manifests     the rendered tree: <component>/<plural kind>.yaml
#                 (deferred components: deferred/<component>/...;
#                 sops-encrypted Secrets, copied verbatim from ./secrets:
#                 deferred/secrets/<namespace>/<name>.sops.yaml)
#   checkImages   a script: every image in the tree must be a manifest list
#                 with linux/amd64 and linux/arm64 (network; not sandboxed)
#   components    the evaluated catenix configurations (for `nix eval`)
#
# parts/k8s.nix exposes it as the system-independent flake output `k8s`
# (built with x86_64-linux pkgs; YAML is the same for every system):
#
#   nix build .#k8s.manifests                      # -> ./result
#   nix build .#k8s.checkImages && ./result/bin/k8s-check-images
#
# This file is the registry: which components exist, the cluster values and
# the Kubernetes version they are rendered with. How they are evaluated and
# laid out (file names, the deferred fence, the image check) is
# ./render.nix; the helpers components share (`k8sLib`) are ./lib.nix.
#
# It is deliberately not a per-system package: rendering is
# import-from-derivation (catenix runs `helm template` in a derivation and
# reads the result back), and `nix flake check` should never build it. The
# NixOS configurations never touch this directory.
#
# Deployment: .github/workflows/render.yml builds the manifests on every push
# to main, pushes them to GHCR as a cosign-signed OCI artifact and pings
# Flux's webhook (k8s/README.md, docs/ci.md).
{
  inputs,
  pkgs,
  lib,
}:
let
  definition = import ../cluster/definition.nix;
  # cluster/definition.nix is pure data today; accept a { lib }: function too.
  cluster = if lib.isFunction definition then definition { inherit lib; } else definition;

  # Kubernetes version the charts are rendered for (`helm template
  # --kube-version`): the (26.05) nixpkgs `kubernetes` package the nodes run.
  kubeVersion = "v1.36.3";

  # Component -> module (a file, or a directory with default.nix). The
  # name is also the component's directory in the render. Flux applies the
  # whole tree (but `deferred`, below) as one Kustomization and orders
  # namespaces and CRDs first by itself; for a manual bootstrap the order is
  # infra/*, then flux, then apps/* (k8s/README.md). Adding a component is
  # one line here (or in `deferred.modules`); ./render.nix needs no change.
  components = {
    "infra/runtime-classes" = ./components/infra/runtime-classes.nix;
    "infra/rbac" = ./components/infra/rbac.nix;
    "infra/local-storage" = ./components/infra/local-storage.nix;
    "infra/flannel" = ./components/infra/flannel.nix;
    "infra/coredns" = ./components/infra/coredns.nix;
    "infra/nvidia-device-plugin" = ./components/infra/nvidia-device-plugin.nix;
    "infra/cert-manager" = ./components/infra/cert-manager;
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
    };
    # sops-encrypted Secrets: every ./secrets/<namespace>/<name>.sops.yaml
    # is copied verbatim (never parsed or re-serialised: that would break
    # the sops MAC) to <dir>/<name>/<namespace>/<name>.sops.yaml and applied
    # by the Kustomization `<name>`, which decrypts them with the age key
    # in flux-system/sops-age (components/flux/secrets.nix, k8s/README.md
    # "Secrets").
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
