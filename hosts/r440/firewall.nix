# r440's own firewall rules. Never open the cluster ports here:
# modules/cluster opens them, to the cluster nodes only.
{ ... }:
{
  networking.firewall = {
    allowedTCPPorts = [ 25565 ];
    # modules/cluster/firewall.nix trusts tailscale0 on every node;
    # ./configuration.nix opens ssh on every interface.
    # tailscaled's WireGuard port, for direct (non-relayed) connections.
    allowedUDPPorts = [ 41641 ];
    # ssh on the direct link to c4130, for remote builds. ./cache.nix opens
    # the cache port per source.
    interfaces.bond0.allowedTCPPorts = [ 22 ];
  };
}
