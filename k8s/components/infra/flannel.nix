# flannel: the pod network (cluster.podCidr), VXLAN, kube-subnet-mgr mode.
# The CNI plugins and conflist come from NixOS (modules/cluster/node.nix),
# so the chart's install-cni init containers are dropped; the DaemonSet only
# runs flanneld.
#
# `transport` picks what VXLAN runs over:
#   "lan"        (default) --public-ip = the node's InternalIP (lanIP), so
#                flanneld never picks the keepalived VIP, bond0 or
#                tailscale0; udp/8472 open between LAN IPs
#   "tailscale"  --iface=tailscale0, MTU 1280 - 50; slower, for nodes that
#                stop sharing a LAN
{
  lib,
  pkgs,
  catenix,
  charts,
  cluster,
  kubeVersion,
  ...
}:
let
  transport = "lan";
  namespace = "kube-flannel";
  healthzPort = 8475;

  transportArgs =
    {
      lan = [ "--public-ip=$(HOST_IP)" ];
      tailscale = [ "--iface=tailscale0" ];
    }
    .${transport};

  hostIPEnv = {
    name = "HOST_IP";
    valueFrom.fieldRef.fieldPath = "status.hostIP";
  };

  # The CNI side belongs to the host: no init containers, no hostPath
  # mounts of /opt/cni/bin or /etc/cni/net.d.
  hostCniVolumes = [
    "cni-plugin"
    "cni"
  ];
  patchPodSpec =
    spec:
    removeAttrs spec [ "initContainers" ]
    // {
      volumes = lib.filter (v: !(lib.elem v.name hostCniVolumes)) spec.volumes;
      containers = map (
        c:
        if c.name == "kube-flannel" then
          c
          // {
            env = c.env ++ [ hostIPEnv ];
            # flanneld runs in the host network, and 8081 (the chart's
            # health port) is taken on c4130 by the LMCache dashboard.
            command = map (
              a: if a == "--healthz-port=8081" then "--healthz-port=${toString healthzPort}" else a
            ) c.command;
            ports = map (
              p: if p.containerPort == 8081 then p // { containerPort = healthzPort; } else p
            ) c.ports;
          }
        else
          c
      ) spec.containers;
    };

  patch =
    m:
    if m.kind == "DaemonSet" && m.metadata.name == "kube-flannel-ds" then
      # Replaced (not recursiveUpdate'd): initContainers must disappear.
      m
      // {
        spec = m.spec // {
          template = m.spec.template // {
            spec = patchPodSpec m.spec.template.spec;
          };
        };
      }
    else
      m;
in
{
  imports = [
    (catenix.importChart {
      inherit pkgs kubeVersion patch;
      chart = charts.flannel;
      release = {
        name = "flannel";
        inherit namespace;
      };
      values = {
        podCidr = cluster.podCidr;
        flannel = {
          backend = "vxlan";
          # The conflist comes from the host (node.nix).
          skipCNIConfigInstallation = true;
          args = [
            "--ip-masq"
            "--kube-subnet-mgr"
          ]
          ++ transportArgs;
        };
      };
    })
  ];

  validation.strict = true;

  # flanneld needs NET_ADMIN/NET_RAW and hostNetwork.
  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "privileged";
  };
}
