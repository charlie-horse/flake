# flannel: the pod network (cluster.podCidr), VXLAN, kube-subnet-mgr mode
# (each node's spec.podCIDR, allocated by kube-controller-manager from
# --cluster-cidr = podCidr with nodeCidrMaskSize, is that node's subnet).
#
# The host side is NixOS (modules/cluster/node.nix): the flannel and
# portmap CNI plugins in /opt/cni/bin and the read-only 10-flannel.conflist
# in /etc/cni/net.d. So the chart's install-cni-plugin / install-cni init
# containers (and their hostPath volumes) are dropped here; the DaemonSet
# only runs flanneld, which writes /run/flannel/subnet.env for the plugin.
#
# Interface: `transport` picks what VXLAN runs over.
#   "lan"        (default) --public-ip = the node's InternalIP
#                (status.hostIP = cluster.nodes.<n>.lanIP, the kubelet's
#                --node-ip). flanneld uses the interface holding that
#                address (eno1 on c4130/r440, end0 on m2mini), so it never
#                picks the keepalived VIP (a second address on the VIP
#                holder's LAN NIC), bond0 or tailscale0. The firewall opens
#                udp/8472 from the nodes' LAN IPs
#                (modules/cluster/firewall.nix).
#   "tailscale"  --iface=tailscale0: VXLAN over the tailnet (trusted
#                interface, so no firewall change), MTU derived from
#                tailscale0 (1280 - 50). Slower; use it if the nodes stop
#                sharing a LAN.
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
