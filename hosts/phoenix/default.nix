# phoenix: a KVM VPS (virtual private server) at Bluehost. Not a node of the
# cluster (not in cluster/definition.nix). Tailscale SSH is the only way in.
# Built with lib mkServer (parts/hosts.nix), never mkHost.
# Install: docs/hosts/vps.md.
{ ... }:
{
  imports = [
    ./configuration.nix
    ./hardware-configuration.nix
  ];
}
