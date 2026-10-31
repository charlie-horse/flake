# kubelet + kube-proxy + container runtime on nodes with the "worker" role.
#
# CRI per node (cluster.nodes.<n>.cri):
#   "containerd" (default): virtualisation.containerd with the CRI plugin,
#       runc as default runtime handler, "nvidia" handler on gpu nodes,
#       optional "crun" handler (clusterNode.crun.enable). Matching
#       RuntimeClasses (runc, nvidia, crun) are cluster objects in k8s/.
#   "cri-o": virtualisation.cri-o; kept working as the alternative.
#
# Networking: flannel runs as a DaemonSet (k8s/), in kube-subnet-mgr mode
# with podCidr. The host provides the CNI side: the flannel + portmap
# plugins in /opt/cni/bin (NixOS kubelet module) and the conflist below in
# /etc/cni/net.d (read-only, from the store), so the DaemonSet must NOT run
# flannel's install-cni / install-cni-plugin init containers.
{ config, lib, pkgs, cluster, ... }:
let
  inherit (lib) mkOption types mkIf mkMerge mkForce;
  cfg = config.clusterNode;
  node = cfg.node;
  secret = cfg.secret;
  kubelet = cfg.leaf "kubelet";
  kubeProxy = cfg.leaf "kube-proxy";
  isContainerd = node.cri == "containerd";
  isCrio = node.cri == "cri-o";

  cniConfigDir = pkgs.writeTextDir "10-flannel.conflist" (builtins.toJSON {
    name = "cbr0";
    cniVersion = "0.3.1";
    plugins = [
      {
        type = "flannel";
        delegate = {
          hairpinMode = true;
          isDefaultGateway = true;
        };
      }
      {
        type = "portmap";
        capabilities.portMappings = true;
      }
    ];
  });

  nodeLabels = node.labels
    // lib.optionalAttrs node.gpu { "nvidia.com/gpu.present" = "true"; };
  nodeLabelsFlag = lib.optionalString (nodeLabels != { })
    ("--node-labels=" + lib.concatStringsSep ","
      (lib.mapAttrsToList (k: v: "${k}=${v}") nodeLabels));

  nvidiaToolkit = config.hardware.nvidia-container-toolkit.package;
  nvidiaRuntime =
    "${lib.getOutput "tools" nvidiaToolkit}/bin/nvidia-container-runtime";
in
{
  options.clusterNode.crun.enable = mkOption {
    type = types.bool;
    default = false;
    description = ''
      Add a "crun" runtime handler to containerd (use it from a pod with
      runtimeClassName: crun once k8s/ defines that RuntimeClass).
    '';
  };

  config = mkIf (cfg.enable && lib.elem "worker" cfg.activeRoles) (mkMerge [
    {
      services.kubernetes.kubelet = {
        enable = true;
        hostname = cfg.name;
        nodeIp = node.lanIP;
        clusterDns = [ cluster.dnsServiceIP ];
        clusterDomain = cluster.clusterDomain;
        clientCaFile = secret "ca.pem";
        # Serving cert (apiserver -> kubelet) and client cert (kubelet ->
        # apiserver, CN system:node:<name>, O system:nodes) are one leaf.
        tlsCertFile = kubelet.cert;
        tlsKeyFile = kubelet.key;
        kubeconfig = {
          server = config.services.kubernetes.apiserverAddress;
          caFile = secret "ca.pem";
          certFile = kubelet.cert;
          keyFile = kubelet.key;
        };
        inherit (node) taints;
        # NixOS sets unschedulable = mkDefault true when roles are all
        # "master", which an empty roles list ([]) also satisfies.
        unschedulable = false;
        cni.configDir = cniConfigDir;
        extraOpts = nodeLabelsFlag;
        # Per-node KubeletConfiguration fields (e.g. c4130's absolute
        # evictionHard / image GC thresholds; its / is 96% full).
        extraConfig = node.kubeletConfig;
      };

      services.kubernetes.proxy = {
        enable = true;
        hostname = cfg.name;
        kubeconfig = {
          server = config.services.kubernetes.apiserverAddress;
          caFile = secret "ca.pem";
          certFile = kubeProxy.cert;
          keyFile = kubeProxy.key;
        };
      };

      # The NixOS kubelet module also loads br_netfilter + overlay and sets
      # net.ipv4.ip_forward and net.bridge.bridge-nf-call-ip{,6}tables to 1.
      # Those sysctls are unique options: hosts must NOT set them as well
      # (a second plain definition, even of the same value, is an error).
      boot.kernelModules = [ "br_netfilter" "overlay" ];
    }

    (mkIf isContainerd {
      virtualisation.containerd = {
        enable = true;
        # Merged over the NixOS kubernetes defaults (version 2 config,
        # runc handler with SystemdCgroup, cni bin_dir /opt/cni/bin, pause
        # image seeded by the kubelet).
        settings.plugins."io.containerd.grpc.v1.cri" = {
          enable_cdi = true;
          cdi_spec_dirs = [ "/etc/cdi" "/var/run/cdi" ];
          containerd = {
            default_runtime_name = "runc";
            runtimes = mkMerge [
              (mkIf node.gpu {
                nvidia = {
                  runtime_type = "io.containerd.runc.v2";
                  options = {
                    BinaryName = nvidiaRuntime;
                    SystemdCgroup = true;
                  };
                };
              })
              (mkIf cfg.crun.enable {
                crun = {
                  runtime_type = "io.containerd.runc.v2";
                  options = {
                    BinaryName = "${pkgs.crun}/bin/crun";
                    SystemdCgroup = true;
                  };
                };
              })
            ];
          };
        };
      };
      services.kubernetes.kubelet.containerRuntimeEndpoint =
        "unix:///run/containerd/containerd.sock";
    })

    (mkIf isCrio {
      virtualisation.containerd.enable = mkForce false;
      virtualisation.cri-o.enable = true;
      # flannel + portmap live in /opt/cni/bin (linked by the kubelet);
      # cri-o's own bridge/loopback examples would shadow flannel and clash
      # with the kubelet's /etc/cni/net.d.
      virtualisation.cri-o.settings.crio.network.plugin_dirs =
        mkForce [ "/opt/cni/bin" ];
      environment.etc."cni/net.d/10-crio-bridge.conflist".enable = false;
      environment.etc."cni/net.d/99-loopback.conflist".enable = false;
      services.kubernetes.kubelet = {
        containerRuntimeEndpoint = "unix:///var/run/crio/crio.sock";
        # The kubelet seeds the pause image with `ctr` (containerd only).
        seedDockerImages = mkForce [ ];
      };
      systemd.services.kubelet = {
        after = [ "crio.service" ];
        requires = [ "crio.service" ];
      };
    })

    (mkIf node.gpu {
      # The NixOS module generates the CDI spec (/var/run/cdi/
      # nvidia-container-toolkit.json) from the host driver.
      hardware.nvidia-container-toolkit.enable = lib.mkDefault true;
      # nvidia-container-runtime in CDI mode: NVIDIA_VISIBLE_DEVICES (as set
      # by the device plugin) is turned into nvidia.com/gpu=<id> devices.
      environment.etc."nvidia-container-runtime/config.toml".text = ''
        disable-require = true
        supported-driver-capabilities = "compat32,compute,display,graphics,ngx,utility,video"
        [nvidia-container-cli]
        environment = []
        ldconfig = "@${lib.getExe' pkgs.glibc "ldconfig"}"
        load-kmods = true
        no-cgroups = false
        path = "${lib.getExe' pkgs.libnvidia-container "nvidia-container-cli"}"
        [nvidia-container-runtime]
        mode = "cdi"
        runtimes = ["runc"]
        [nvidia-container-runtime.modes.cdi]
        default-kind = "nvidia.com/gpu"
        spec-dirs = ["/etc/cdi", "/var/run/cdi"]
        [nvidia-container-runtime-hook]
        path = "${lib.getOutput "tools" nvidiaToolkit}/bin/nvidia-container-runtime-hook"
        skip-mode-detection = false
        [nvidia-ctk]
        path = "${lib.getExe' nvidiaToolkit "nvidia-ctk"}"
      '';
    })
  ]);
}
