# Host side of the "solaris" Kubernetes cluster (manual services.kubernetes,
# no easyCerts, no roles, no addons: CoreDNS, flannel, the NVIDIA device
# plugin, RuntimeClasses and Flux are rendered with catenix under k8s/).
#
# Import it on a server and pass two specialArgs (lib/system/mkServer.nix
# does both):
#   cluster  = import ./cluster/definition.nix;   # pure data, see that file
#   hostName = "<node name>";                     # key in cluster.nodes
# What the node runs follows its roles in the definition:
#   etcd         -> ./etcd.nix          (member <name>, https://<name>:2380)
#   controlPlane -> ./control-plane.nix (apiserver, controller-manager,
#                                         scheduler; leader election)
#   worker       -> ./node.nix          (kubelet, kube-proxy, containerd or
#                                         cri-o, NVIDIA runtime on gpu nodes)
#   every node   -> ./keepalived.nix    (apiserver VIP, local /readyz check)
#                   ./firewall.nix      (cluster ports open to the nodes only)
#
# Secrets: every key and cert is a STRING path under cluster.secretsDir
# (/var/lib/kubernetes/secrets), put there by `cluster-pki deploy`
# (pkgs/cluster-pki). Nothing secret is a Nix path, so nothing secret is
# ever copied into /nix/store. File names:
#   ca.pem etcd-ca.pem front-proxy-ca.pem sa.pub sa.key
#   <component>-<node>.pem / <component>-<node>-key.pem
{ config, lib, cluster, hostName, ... }:
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

    secretsDir = mkOption {
      # A string on purpose: a Nix path here would copy keys into the store.
      type = types.str;
      default = cluster.secretsDir or "/var/lib/kubernetes/secrets";
      description = "Directory holding every cluster key and cert.";
    };

    # ---- read-only values shared by the sub-modules -----------------------
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
      description = "name -> string path of a file in secretsDir.";
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
          extraSANs = [ ];
          roles = [ ];
        } // (cluster.nodes.${cfg.name} or { });
        secret = n: "${cfg.secretsDir}/${n}";
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
          assertion = lib.hasPrefix "/" cfg.secretsDir
            && !(lib.hasPrefix builtins.storeDir cfg.secretsDir);
          message = ''
            clusterNode.secretsDir must be an absolute path outside the
            Nix store (got ${cfg.secretsDir}).
          '';
        }
        {
          assertion = lib.elem cfg.node.cri [ "containerd" "cri-o" ];
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
        apiserverAddress =
          "https://${cluster.vip}:${toString cluster.apiserverPort}";
        clusterCidr = cluster.podCidr;
      };
    })
  ];
}
