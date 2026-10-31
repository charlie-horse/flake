# r440: Dell R440 (x86_64, NixOS 26.05). etcd member, control plane,
# Nix remote builder + harmonia cache for c4130 over bond0 (10.25.0.2/30).
#
# Ported from r440's standalone flake (/etc/nixos, via
# ~/flint-nix/builder/etc-nixos). Its old k8s.nix (etcd, apiserver,
# controller-manager, scheduler, cri-o, certs as Nix paths, clusterCidr
# bug) is intentionally NOT here: the shared cluster module (modules/cluster
# + cluster/definition.nix) replaces it, as it does the cluster-port
# firewall rules (./legacy-k8s-firewall.nix, not imported).
#
# Must NOT go through lib mkHost (that imports every modules/** file:
# desktop, home-manager, agenix). Build it with nixpkgs.lib.nixosSystem,
# nixpkgs = github:NixOS/nixpkgs/nixos-26.05 at
# c3eea5b2156db11c7eeeada3dc737711255b253e. No specialArgs needed.
#
# Module order matters for byte-identical output; keep it as in the host
# flake (configuration -> hardware -> [k8s] -> builder -> firewall).
{ ... }:
{
  imports = [
    ./configuration.nix
    ./builder.nix
    ./firewall.nix
    ./containers.nix
  ];
}
