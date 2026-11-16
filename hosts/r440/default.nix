# r440: Dell R440 (x86_64, NixOS 26.05). etcd member, control plane,
# Nix remote builder for c4130 and binary cache (./builder.nix, ./cache.nix).
# Built with lib mkServer (parts/hosts.nix), never mkHost.
# Host doc: docs/hosts/r440.md
{ ... }:
{
  imports = [
    ./configuration.nix
    ./builder.nix
    ./cache.nix
    ./firewall.nix
    ./containers.nix
    ./memory.nix
  ];
}
