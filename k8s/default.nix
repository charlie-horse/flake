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
  catenix = inputs.catenix;

  definition = import ../cluster/definition.nix;
  # cluster/definition.nix is pure data today; accept a { lib }: function too.
  cluster = if lib.isFunction definition then definition { inherit lib; } else definition;

  # Kubernetes version the charts are rendered for (`helm template
  # --kube-version`): the (26.05) nixpkgs `kubernetes` package the nodes run.
  kubeVersion = "v1.36.3";

  # Component -> module (a file, or a directory with default.nix). The
  # name is also the component's directory in the render. Flux applies the
  # whole tree as one Kustomization and orders namespaces and CRDs first by
  # itself; for a manual bootstrap the order is infra/*, then flux, then
  # apps/* (k8s/README.md).
  components = {
    "infra/runtime-classes" = ./components/infra/runtime-classes.nix;
    "infra/rbac" = ./components/infra/rbac.nix;
    "infra/local-storage" = ./components/infra/local-storage.nix;
    "infra/flannel" = ./components/infra/flannel.nix;
    "infra/coredns" = ./components/infra/coredns.nix;
    "infra/nvidia-device-plugin" = ./components/infra/nvidia-device-plugin.nix;
    "flux" = ./components/flux;
    "apps/cloudflared" = ./components/apps/cloudflared;
    "apps/authentik" = ./components/apps/authentik;
    "apps/headlamp" = ./components/apps/headlamp.nix;
    "apps/open-webui" = ./components/apps/open-webui.nix;
  };

  evalComponent =
    module:
    lib.evalModules {
      modules = [
        catenix.nixosModules.default
        module
      ];
      specialArgs = {
        inherit pkgs cluster kubeVersion;
        catenix = catenix.lib;
        k8sLib = import ./lib.nix { inherit lib cluster; };
        charts = import ./charts.nix { inherit pkgs catenix; };
      };
    };

  evaluated = lib.mapAttrs (_: evalComponent) components;

  header = name: kind: ''
    # Generated from k8s/components (catenix); do not edit, change the Nix
    # source. Component: ${name}, kind: ${kind}
  '';

  # Lower-case plural of a kind, as kubectl names resources: Deployment ->
  # deployments, NetworkPolicy -> networkpolicies, Ingress -> ingresses.
  plural =
    kind:
    let
      k = lib.toLower kind;
    in
    if lib.hasSuffix "y" k then
      lib.removeSuffix "y" k + "ies"
    else if lib.hasSuffix "s" k then
      k + "es"
    else
      k + "s";

  # One file per kind and component, named by the plural: e.g.
  # apps/authentik/deployments.yaml (namespaces and CRDs get a 00-/01-
  # prefix, see below). (Never the singular: Flux's Kustomization
  # kind would become kustomization.yaml, the file name kustomize reserves
  # for its own config, which would break Flux's build of the artifact.)
  # Each is rendered like a whole component (catenix's toYaml: namespaces,
  # then CRDs, then the rest).
  componentFiles =
    name: config:
    lib.mapAttrsToList (
      kind: objects:
      let
        # Namespaces and CRDs sort first, so `kubectl apply -R` (which walks
        # files alphabetically) creates them before what needs them.
        prefix =
          {
            Namespace = "00-";
            CustomResourceDefinition = "01-";
          }
          .${kind} or "";
        file = "${prefix}${plural kind}.yaml";
      in
      assert lib.assertMsg (
        !lib.elem file [
          "kustomization.yaml"
          "kustomization.yml"
        ]
      ) "k8s render: ${name}/${file} is a name kustomize reserves";
      {
        path = "${name}/${file}";
        header = header name kind;
        yaml = catenix.lib.render.toYaml pkgs objects;
      }
    ) (lib.groupBy (m: m.kind) config.config.build.manifests);

  manifests = pkgs.runCommand "k8s-manifests" { } (
    lib.concatMapStrings (f: ''
      mkdir -p "$(dirname "$out/${f.path}")"
      {
        cat ${pkgs.writeText "header" f.header}
        cat ${f.yaml}
      } > "$out/${f.path}"
    '') (lib.concatLists (lib.mapAttrsToList componentFiles evaluated))
  );

  checkImages = pkgs.writeShellApplication {
    name = "k8s-check-images";
    runtimeInputs = [
      pkgs.crane
      pkgs.jq
      pkgs.yq-go
      pkgs.gnugrep
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      # Images pinned to the gpu node (x86_64 only) are exempt.
      single_arch='^nvcr\.io/nvidia/k8s-device-plugin:'
      status=0
      images=$(find ${manifests} -name '*.yaml' -exec yq -N '.. | select(has("image")) | .image' {} + \
        | sort -u)
      for image in $images; do
        platforms=$(crane manifest "$image" \
          | jq -r '[.manifests[]?.platform | select(.os != "unknown")
                   | "\(.os)/\(.architecture)"]
                   | join(" ")')
        if echo "$platforms" | grep -q 'linux/amd64' \
          && echo "$platforms" | grep -q 'linux/arm64'; then
          echo "ok      $image ($platforms)"
        elif echo "$image" | grep -qE "$single_arch"; then
          echo "pinned  $image ($platforms)"
        else
          echo "MISSING $image ($platforms)" >&2
          status=1
        fi
      done
      exit "$status"
    '';
  };
in
{
  inherit manifests checkImages;
  components = evaluated;
}
