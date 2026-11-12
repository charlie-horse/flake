# The k8s render (../k8s) as a system-independent flake output, `k8s`:
#
#   nix build .#k8s.manifests        the rendered tree (what Flux applies)
#   nix build .#k8s.checkImages      script: are all images amd64 + arm64?
#   nix eval  .#k8s.components...    the evaluated catenix configurations
#
# Not under packages.<system> on purpose: the render needs
# import-from-derivation (helm template), so anything that evaluates the
# per-system outputs (`nix flake check`) would build it. The YAML is the same
# for every system, so one build with the nodes' 26.05 nixpkgs on
# x86_64-linux serves all.
{ inputs, ... }:
{
  flake.k8s = import ../k8s {
    inherit inputs;
    pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
    lib = inputs.nixpkgs.lib;
  };
}
