# Cluster ports, open to the cluster nodes only (iptables nixos-fw chain,
# as r440's firewall.nix did for 2379/2380/6443):
#   tcp 2379, 2380   etcd client/peer     (etcd nodes)
#   tcp 6443         kube-apiserver / VIP (controlPlane nodes, and the
#                                          HAProxy on other VIP nodes)
#   tcp 10250        kubelet              (workers)
#   udp 8472         flannel VXLAN        (workers)
#   VRRP (proto 112) keepalived           (every node)
# Sources: every node's LAN IP and the VIP. tailscale0 carries most
# node-to-node traffic (the cluster names resolve to tailnet IPs): it is
# trusted on nodes with trustTailscale = true (default); otherwise only the
# node's cluster ports above are opened on it (c4130). Pods (podCidr) may reach the local apiserver
# and kubelet (in-cluster clients, metrics-server).
{ config, lib, cluster, ... }:
let
  inherit (lib) mkOption types mkIf concatStrings concatStringsSep;
  cfg = config.clusterNode;
  node = cfg.node;
  has = r: lib.elem r cfg.activeRoles;
  vipHolder = cfg.keepalived.enable;
  apiserverHere = has "controlPlane" || vipHolder;

  tcpPorts = lib.optionals (has "etcd") [ 2379 2380 ]
    ++ lib.optional apiserverHere cluster.apiserverPort
    ++ lib.optional (has "worker") 10250;
  udpPorts = lib.optional (has "worker") 8472;
  podTcpPorts = lib.optional apiserverHere cluster.apiserverPort
    ++ lib.optional (has "worker") 10250;

  nodeSources = lib.unique
    (lib.mapAttrsToList (_: n: n.lanIP) cluster.nodes ++ [ cluster.vip ]);

  ports = ps: concatStringsSep "," (map toString ps);
  accept = proto: dports: src:
    lib.optionalString (dports != [ ]) ''
      iptables -A nixos-fw -p ${proto} -s ${src} -m multiport --dports ${ports dports} -j nixos-fw-accept
    '';
in
{
  options.clusterNode.firewall.apiserverAllowedSources = mkOption {
    type = types.listOf types.str;
    default = [ ];
    example = [ "10.0.0.0/16" ];
    description = ''
      Extra sources (IPs/CIDRs) allowed to reach the apiserver port on this
      node (e.g. LAN admins using the VIP). Cluster nodes and tailscale0
      (whole interface, or its cluster ports with trustTailscale = false)
      are always allowed.
    '';
  };

  config = mkIf cfg.enable {
    networking.firewall = {
      enable = lib.mkDefault true;
      trustedInterfaces = lib.optional node.trustTailscale "tailscale0";
      interfaces.tailscale0 = mkIf (!node.trustTailscale) {
        allowedTCPPorts = tcpPorts;
        allowedUDPPorts = udpPorts;
      };
      extraCommands = concatStrings (
        map (src: accept "tcp" tcpPorts src + accept "udp" udpPorts src)
          nodeSources
        ++ [ (accept "tcp" podTcpPorts cluster.podCidr) ]
        ++ map (accept "tcp" [ cluster.apiserverPort ])
          (lib.optionals apiserverHere cfg.firewall.apiserverAllowedSources)
        ++ lib.optionals vipHolder (map (src: ''
          iptables -A nixos-fw -p vrrp -s ${src} -j nixos-fw-accept
        '') (lib.remove node.lanIP
          (lib.mapAttrsToList (_: n: n.lanIP) cluster.nodes)))
      );
    };
  };
}
