# The apiserver VIP (virtual IP, cluster.vip), held by keepalived on every
# node. Nodes talk VRRP (the failover protocol) over the LAN, unicast. The
# highest-priority node whose local apiserver answers /readyz holds the
# VIP. /readyz needs no client cert.
{
  config,
  lib,
  pkgs,
  cluster,
  ...
}:
let
  inherit (lib) mkOption types mkIf;
  cfg = config.clusterNode;
  node = cfg.node;
  port = toString cluster.apiserverPort;
  isControlPlane = lib.elem "controlPlane" cfg.activeRoles;
  others = lib.filterAttrs (n: _: n != cfg.name) cluster.nodes;
  controlPlanes = lib.filterAttrs (_: n: lib.elem "controlPlane" n.roles) cluster.nodes;
in
{
  options.clusterNode.keepalived.enable = mkOption {
    type = types.bool;
    # Not in the "etcd" stage: no apiserver runs there.
    default = cfg.stage != "etcd";
    defaultText = "clusterNode.stage != \"etcd\"";
    description = "Run keepalived for the apiserver VIP on this node.";
  };

  config = mkIf (cfg.enable && cfg.keepalived.enable) {
    services.keepalived = {
      enable = true;
      enableScriptSecurity = true;
      # VRRP is opened to the cluster nodes only, in ./firewall.nix.
      openFirewall = false;
      vrrpScripts.apiserver_readyz = {
        script = lib.concatStringsSep " " [
          "${pkgs.curl}/bin/curl"
          "--silent --fail --insecure --max-time 2 --output /dev/null"
          "https://127.0.0.1:${port}/readyz"
        ];
        interval = 2;
        timeout = 3;
        fall = 3;
        rise = 2;
        # weight 0: a failing check puts the instance in FAULT state.
        weight = 0;
        user = "keepalived_script";
      };
      vrrpInstances.apiserver = {
        interface = node.lanInterface;
        state = "BACKUP";
        virtualRouterId = cluster.virtualRouterId;
        priority = node.keepalivedPriority;
        unicastSrcIp = node.lanIP;
        unicastPeers = lib.mapAttrsToList (_: n: n.lanIP) others;
        virtualIps = [
          { addr = "${cluster.vip}/${toString cluster.vipPrefixLength}"; }
        ];
        trackScripts = [ "apiserver_readyz" ];
      };
    };

    users.users.keepalived_script = {
      isSystemUser = true;
      group = "keepalived_script";
      description = "keepalived health-check scripts";
    };
    users.groups.keepalived_script = { };

    # Nodes without an apiserver: TCP proxy to the ready apiservers.
    services.haproxy = mkIf (!isControlPlane) {
      enable = true;
      config = ''
        global
          log stdout format raw local0 info

        defaults
          mode tcp
          log global
          option tcplog
          timeout connect 5s
          timeout client 1h
          timeout server 1h

        frontend kube-apiserver
          bind *:${port}
          default_backend apiservers

        backend apiservers
          option httpchk GET /readyz
          http-check expect status 200
          balance roundrobin
          default-server inter 2s fall 3 rise 2 check check-ssl verify none
      ''
      + lib.concatStrings (
        lib.mapAttrsToList (n: v: ''
          server ${n} ${v.lanIP}:${port}
        '') controlPlanes
      );
    };
  };
}
