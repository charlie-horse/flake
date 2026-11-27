# r440: a cluster node that is also the Nix remote builder for c4130 and
# the binary cache (./builder.nix, ./cache.nix).
# Built with lib mkServer (parts/hosts.nix), never mkHost.
{ ... }:
{
  imports = [
    ./configuration.nix
    ./builder.nix
    ./cache.nix
    ./firewall.nix
    ./containers.nix
    ./memory.nix
    ./files.nix
  ];
}
