# Host side of the "neurosis" Kubernetes cluster (manual services.kubernetes,
# no easyCerts, no roles, no addons: those are rendered with catenix under k8s/).
#
# Needs two specialArgs (lib/system/mkServer.nix passes both):
#   cluster  = import ./cluster/definition.nix;   # pure data
#   hostName = "<node name>";                     # key in cluster.nodes
# What the node runs follows its roles (etcd.nix, control-plane.nix,
# tailscale-service.nix, node.nix; keepalived.nix and firewall.nix on every
# node), limited by clusterNode.stage (cluster.nodes.<n>.rollout.stage).
#
# Every key and cert is a STRING path under /run/secrets/pki (sops-nix,
# ./pki-sops.nix), so nothing secret is ever copied into /nix/store.
{
  config,
  lib,
  cluster,
  hostName,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.clusterNode;
in
{
  imports = [
    ./etcd.nix
    ./control-plane.nix
    ./node.nix
    ./keepalived.nix
    ./firewall.nix
    ./tailscale-service.nix
    ./pki-sops.nix
  ];

  options.clusterNode = {
    enable = mkOption {
      type = types.bool;
      default = cluster.nodes ? ${hostName};
      defaultText = "whether hostName is a key of cluster.nodes";
      description = "Configure this host as a node of the cluster.";
    };

    name = mkOption {
      type = types.str;
      default = hostName;
      description = ''
        Node name: etcd member name, Kubernetes node name, cert suffix.
      '';
    };

    stage = mkOption {
      type = types.enum [
        "etcd"
        "controlPlane"
        "full"
      ];
      default = cfg.node.rollout.stage or "full";
      defaultText = "cluster.nodes.<name>.rollout.stage or \"full\"";
      description = ''
        Rollout stage: which of the node's roles
        actually run. "etcd": etcd only; "controlPlane": + apiserver,
        controller-manager, scheduler and keepalived; "full": every role.
      '';
    };

    # ---- read-only values shared by the sub-modules -----------------------
    activeRoles = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      internal = true;
      description = "The node's roles that run in the current stage.";
    };
    node = mkOption {
      type = types.attrs;
      readOnly = true;
      internal = true;
      description = "This node's entry of cluster.nodes, with defaults.";
    };
    secret = mkOption {
      type = types.functionTo types.str;
      readOnly = true;
      internal = true;
      description = "name -> string path of a file in /run/secrets/pki.";
    };
    leaf = mkOption {
      type = types.functionTo (types.attrsOf types.str);
      readOnly = true;
      internal = true;
      description = "component -> { cert; key; } string paths for this node.";
    };
  };

  config = lib.mkMerge [
    {
      clusterNode = {
        node = {
          gpu = false;
          cri = "containerd";
          keepalivedPriority = 100;
          labels = { };
          taints = { };
          trustTailscale = true;
          extraSANs = [ ];
          kubeletConfig = { };
          rollout = { };
          roles = [ ];
        }
        // (cluster.nodes.${cfg.name} or { });
        activeRoles = lib.filter (
          r:
          lib.elem r (
            {
              etcd = [ "etcd" ];
              controlPlane = [
                "etcd"
                "controlPlane"
              ];
              full = [
                "etcd"
                "controlPlane"
                "worker"
              ];
            }
            .${cfg.stage}
          )
        ) cfg.node.roles;
        secret = n: "/run/secrets/pki/${n}";
        leaf = component: {
          cert = cfg.secret "${component}-${cfg.name}.pem";
          key = cfg.secret "${component}-${cfg.name}-key.pem";
        };
      };
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cluster.nodes ? ${cfg.name};
          message = "clusterNode: ${cfg.name} is not in cluster.nodes.";
        }
        {
          assertion = lib.elem cfg.node.cri [
            "containerd"
            "cri-o"
          ];
          message = "clusterNode: cri must be \"containerd\" or \"cri-o\".";
        }
        {
          assertion = cfg.node.gpu -> cfg.node.cri == "containerd";
          message = ''
            clusterNode: the NVIDIA runtime handler is only wired for
            containerd (node ${cfg.name} has gpu = true, cri = cri-o).
          '';
        }
      ];

      # dhcpcd runs on every interface unless told otherwise; on a LAN
      # carrier loss it drops the LAN address and routes and adds an IPv4LL
      # default route via flannel.1, cutting the node off every apiserver.
      #   - deny the CNI, overlay and tailscale interfaces (pod veths, cni0,
      #     flannel.1, tailscale0 are never DHCP clients). A list: merges
      #     with the hosts' own entries (bond0 etc. in hosts/*/builder.nix).
      #   - persistent: keep the LAN address (and with it the node's own
      #     apiserver endpoint and etcd peer address) when carrier drops.
      networking.dhcpcd = {
        denyInterfaces = [
          "veth*"
          "cni*"
          "flannel*"
          "tailscale*"
        ];
        persistent = true;
      };

      # Manual PKI: no easyCerts / certmgr / cfssl, no roles (they would
      # turn easyCerts and flannel back on), no NixOS addons (CoreDNS etc.
      # come from k8s/ via Flux).
      services.kubernetes = {
        easyCerts = false;
        pki.enable = false;
        roles = [ ];
        flannel.enable = false;
        addonManager.enable = false;
        addons.dns.enable = false;
        caFile = cfg.secret "ca.pem";
        # Only used by NixOS defaults we override; the VIP is the stable
        # apiserver address.
        masterAddress = cluster.vip;
        apiserverAddress = "https://${cluster.vip}:${toString cluster.apiserverPort}";
        clusterCidr = cluster.podCidr;
      };

      # The kubelet module sets net.ipv4.ip_forward = 1 (hosts rely on it,
      # e.g. for Tailscale). Keep it in the stages without a kubelet; a
      # second definition next to the kubelet's would be a conflict.
      boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkIf (!config.services.kubernetes.kubelet.enable) 1;
    })
  ];
}
