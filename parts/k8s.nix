# The k8s render (../k8s) as a system-independent flake output, `k8s`:
#
#   nix build .#k8s.manifests        the rendered tree (what Flux applies)
#   nix build .#k8s.checkImages      script: are all images amd64 + arm64?
#   nix eval  .#k8s.components...    the evaluated catenix configurations
#
# The YAML is the same for every system; this output is the x86_64-linux
# build, which CI publishes. `nix flake check` renders it with each system's
# nixpkgs (parts/checks.nix). It needs import-from-derivation (helm template).
{ inputs, ... }:
{
  flake.k8s = import ../k8s {
    inherit inputs;
    pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
    lib = inputs.nixpkgs.lib;
  };
}
