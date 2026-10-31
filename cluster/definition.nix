# Cluster definition for the "solaris" cluster (c4130, r440, m2mini).
#
# PURE DATA: no functions, no Nix paths, no secrets. Everything that needs
# the cluster layout reads this file:
#   - modules/cluster (NixOS host config: etcd, control plane, kubelet,
#     containerd, keepalived, firewall), via the `cluster` specialArg that
#     lib/system/mkServer.nix passes in;
#   - pkgs/cluster-pki (cert subjects/SANs, which leaves each node gets);
#   - k8s/ (catenix manifests: CoreDNS IP, pod CIDR for flannel, ...).
#
# Shape (keep it stable; add fields, don't rename them):
#   name                 string  cluster name (CA subject O, kubeconfig names)
#   domain               string  tailnet DNS domain; nodes are <name>.<domain>
#                                and MagicDNS resolves the bare <name> to the
#                                node's tailnet IP (etcd/apiserver use that)
#   vip                  string  keepalived apiserver VIP (IPv4, on the LAN)
#   vipPrefixLength      int     prefix length the VIP is added with
#   virtualRouterId      int     VRRP router id of the VIP
#   apiserverPort        int     kube-apiserver secure port (VIP and nodes)
#   podCidr              string  pod network (flannel, --cluster-cidr)
#   nodeCidrMaskSize     int     per-node pod subnet size
#   serviceCidr          string  --service-cluster-ip-range
#   kubernetesServiceIP  string  first IP of serviceCidr (apiserver SAN)
#   dnsServiceIP         string  CoreDNS Service IP (kubelet clusterDNS)
#   clusterDomain        string  cluster DNS domain
#   secretsDir           string  where every key/cert lives on a node
#   nodes.<name>         attrs, keyed by hostname (= etcd member name =
#                        Kubernetes node name = cert CN suffix):
#     system             "x86_64-linux" | "aarch64-linux"
#     lanIP              string  LAN address (node InternalIP, VRRP, VXLAN)
#     lanInterface       string  LAN NIC (VRRP interface)
#     tailnetIP          string  Tailscale address (what <name> resolves to)
#     roles              list of "etcd" | "controlPlane" | "worker"
#     gpu                bool    NVIDIA GPUs (container toolkit, nvidia
#                                RuntimeClass handler, gpu.present label)
#     cri                "containerd" | "cri-o"
#     keepalivedPriority int     VRRP priority (highest healthy node holds
#                                the VIP)
#     labels             attrs of string  extra kubelet --node-labels
#                        (kubernetes.io/arch etc. are set by the kubelet)
#     taints             attrs of { key?; value; effect; }  kubelet
#                        --register-with-taints (NixOS kubelet.taints shape)
#     extraSANs          list of string  extra SANs for this node's leaves
{
  name = "solaris";
  domain = "leaffish-monster.ts.net";

  vip = "10.0.0.200";
  vipPrefixLength = 16;
  virtualRouterId = 2;
  apiserverPort = 6443;

  podCidr = "10.244.0.0/16";
  nodeCidrMaskSize = 24;
  serviceCidr = "10.96.0.0/12";
  kubernetesServiceIP = "10.96.0.1";
  dnsServiceIP = "10.96.0.10";
  clusterDomain = "cluster.local";

  secretsDir = "/var/lib/kubernetes/secrets";

  nodes = {
    c4130 = {
      system = "x86_64-linux";
      lanIP = "10.0.0.95";
      lanInterface = "eno1";
      tailnetIP = "100.74.71.16";
      roles = [ "etcd" "controlPlane" "worker" ];
      gpu = true;
      cri = "containerd";
      keepalivedPriority = 150;
      labels = { };
      taints = { };
      extraSANs = [ ];
    };

    r440 = {
      system = "x86_64-linux";
      lanIP = "10.0.0.239";
      lanInterface = "eno1";
      tailnetIP = "100.81.238.37";
      roles = [ "etcd" "controlPlane" "worker" ];
      gpu = false;
      cri = "containerd";
      keepalivedPriority = 100;
      labels = { };
      taints = { };
      extraSANs = [ ];
    };

    m2mini = {
      system = "aarch64-linux";
      lanIP = "10.0.0.147";
      lanInterface = "end0";
      tailnetIP = "100.71.194.116";
      roles = [ "etcd" "worker" ];
      gpu = false;
      cri = "containerd";
      keepalivedPriority = 50;
      labels = { };
      taints = { };
      extraSANs = [ ];
    };
  };
}
