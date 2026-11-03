# c4130: 2x V100 vLLM inference host (x86_64, NixOS 26.05).
#
# Ported verbatim from c4130's standalone flake (/etc/nixos, via
# ~/flint-nix/builder/etc-nixos-c4130). The old k8s.nix (etcd, apiserver,
# keepalived, certs as Nix paths) is intentionally NOT here: the shared
# cluster module (modules/cluster + cluster/definition.nix) replaces it.
#
# Must NOT go through lib mkHost (that imports every modules/** file:
# desktop, home-manager, agenix). Build it with nixpkgs.lib.nixosSystem.
#
# Required specialArgs:
#   inputs   - flake inputs; needs inputs.vllm-fork
#              (github:charlie-horse/vLLM/latest, inputs.nixpkgs.follows =
#              the 26.05 nixpkgs)
# nixpkgs itself: github:NixOS/nixpkgs/nixos-26.05 at
# c3eea5b2156db11c7eeeada3dc737711255b253e.
#
# Module order matters for byte-identical output (list-merged options such
# as firewall ports); keep it as in the host flake.
{ ... }:
{
  imports = [
    ./configuration.nix
    ./hardware-configuration.nix
    ./vllm
    ./builder.nix
    ./cloudflared.nix
  ];
}
