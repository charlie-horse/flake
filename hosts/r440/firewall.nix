# Firewall for r440, host part (iptables backend, ping allowed, as on
# c4130). The cluster ports (etcd 2379/2380, apiserver 6443, kubelet,
# flannel) are NOT opened here: the cluster module (modules/cluster) owns
# them, restricted to the cluster peers. docs/hosts/r440.md#firewall
{ ... }:
{
  networking.firewall = {
    # tailscale0 (admins + the cluster nodes, whose names resolve to 100.x
    # via MagicDNS) is trusted by modules/cluster/firewall.nix on every node.
    # ssh (22) is opened in ./configuration.nix on every interface.
    # tailscaled's WireGuard port, for direct (non-relayed) connections.
    allowedUDPPorts = [ 41641 ];
    # The 25G link to c4130: ssh (remote builds). The cache's nginx port
    # (5080) is opened per source in ./cache.nix.
    interfaces.bond0.allowedTCPPorts = [ 22 ];
  };
}
