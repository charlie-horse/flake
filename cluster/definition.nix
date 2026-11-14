# Cluster definition for the "neurosis" cluster (c4130, r440, m2mini).
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
#   name                 string  cluster name: kube-controller-manager
#                                --cluster-name, and the subject of any CA
#                                cluster-pki creates (existing CAs keep
#                                theirs; docs/pki.md)
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
#     sshHostKey         string  public half of /etc/ssh/ssh_host_ed25519_key
#                        ("ssh-ed25519 AAAA...", no comment). Pinned in
#                        every host's ssh_known_hosts (modules/programs/
#                        ssh.nix); Tailscale SSH presents the same key. Its
#                        ssh-to-age is the host's anchor in .sops.yaml, so a
#                        reinstalled host changes both.
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
#     trustTailscale     bool (default true)  trust all of tailscale0; when
#                        false only this node's cluster ports are opened there
#     extraSANs          list of string  extra SANs for this node's leaves
#     kubeletConfig      attrs  merged into the KubeletConfiguration
#                        (services.kubernetes.kubelet.extraConfig), e.g.
#                        evictionHard / image GC thresholds per node
#     rollout            { stage; etcdPhase; certSource; }  where this node is in the
#                        cut-over from the legacy cluster (docs/
#                        history/cluster-handoff-2026-10.md). The cut-over is done: every
#                        node is at stage "full", etcdPhase "final".
#                        Flip these per step:
#       stage      "etcd"          only etcd (+ firewall) runs
#                  "controlPlane"  + apiserver/controller-manager/scheduler
#                                  + keepalived (the VIP)
#                  "full"          + kubelet/kube-proxy/containerd (end state)
#       etcdPhase  "trust"  new etcd-ca.pem bundle (new + legacy CA), but the
#                           LEGACY leaves, copied to secretsDir as
#                           legacy-etcd-peer-<n>{,-key}.pem and (control
#                           planes) legacy-etcd-client-apiserver-<n>{,-key}.pem;
#                           peerClientCertAuth off, as today
#                  "final"  new etcd-server/-peer/-client-apiserver leaves,
#                           peerClientCertAuth on (end state)
#       certSource "files"  from `cluster-pki deploy` (default)
#                  "sops"   modules/cluster/pki-sops.nix; needs etcdPhase "final"
#   apiserverTailscaleService  optional string  name of the Tailscale Service
#                        (svc:<name>) every controlPlane node hosts for the
#                        apiserver port; clients use <name>.<domain>:6443.
#                        Absent = off. Read by
#                        modules/cluster/tailscale-service.nix
#   apiserverExtraSANs   list of string  extra SANs on every apiserver leaf
#                        (must hold <apiserverTailscaleService>.<domain>)
#   oidc                 optional { issuerUrl; audiences; extraIssuers?; }
#                        kube-apiserver OIDC (JWT) login; absent = off.
#                        extraIssuers: list of { issuerUrl; audiences; },
#                        one more JWT authenticator each (authentik issues
#                        per provider, so every client is its own issuer).
#                        Read by modules/cluster/control-plane.nix
#                        (clusterNode.oidc)
#   tunnel               { name; id; }  the one Cloudflare tunnel; run in
#                        the cluster by k8s/components/cloudflared.nix (one
#                        replica per node). Every public hostname below goes
#                        through it.
#   authentik            { host; serviceIP; }  public hostname (on the
#                        tunnel) and the fixed ClusterIP of Service
#                        authentik/authentik-server (in the static band of
#                        serviceCidr) the tunnel's proxy forwards to
#   headlamp             { host; serviceIP; }  same for Headlamp
#                        (k8s/components/headlamp.nix), Service
#                        headlamp/headlamp
#   openWebui            { host; serviceIP; }  same for Open WebUI
#                        (k8s/components/open-webui.nix), Service
#                        open-webui/open-webui
#   binaryCache          { host; node; port; publicKey; }  r440's Nix
#                        binary cache (harmonia): public hostname on the
#                        tunnel, the node serving it, the port of the
#                        authenticated nginx in front of it on that node's
#                        lanIP (hosts/r440/cache.nix; the tunnel's proxy
#                        forwards there), and the signing public key that
#                        clients trust (modules/system/nix-cache.nix)
{
  name = "neurosis";
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

  # Tailscale Service for the API (modules/cluster/tailscale-service.nix):
  # every controlPlane node hosts svc:kube-api, TCP 6443 -> its local
  # apiserver, reachable tailnet-wide as kube-api.<domain>:6443.
  apiserverTailscaleService = "kube-api";

  # Extra SANs on every apiserver leaf. Re-issue all apiserver leaves with
  # cluster-pki (on r440) and deploy them after changing this (docs/pki.md).
  # The Tailscale Service name must be here for kubectl to verify TLS.
  apiserverExtraSANs = [ "kube-api.leaffish-monster.ts.net" ];

  # The single Cloudflare tunnel (locally managed: the ingress rules live in
  # k8s/components/cloudflared.nix). Its credential is the Secret
  # cloudflared/tunnel-credentials, made by hand, never in git.
  tunnel = {
    name = "cluster";
    id = "59a275ca-be31-4f8d-99ce-c536eaf490f8";
  };

  # Public services: cloudflared -> its nginx sidecar -> http://<serviceIP>:80.
  # authentik (k8s/components/authentik.nix).
  authentik = {
    host = "auth.neuros.is";
    serviceIP = "10.96.0.20";
  };

  # Headlamp (k8s/components/headlamp.nix).
  headlamp = {
    host = "k8s.neuros.is";
    serviceIP = "10.96.0.21";
  };

  # Open WebUI (k8s/components/open-webui.nix), chat front-end for c4130's
  # vLLM; logins through authentik (group local-ai).
  openWebui = {
    host = "chat.neuros.is";
    serviceIP = "10.96.0.22";
  };

  fluxWebhook = {
    host = "flux.neuros.is";
    serviceIP = "10.96.0.23";
  };

  # r440's Nix binary cache (harmonia). Not a Service: the tunnel's nginx
  # sidecar forwards to http://<nodes.r440.lanIP>:<port>, where nginx on
  # r440 asks for HTTP basic auth (hosts/r440/cache.nix). The signing key
  # stays on r440 (sops key harmonia-signing-key in secrets/r440.yaml; was
  # /var/lib/secrets/harmonia.secret); this is its public half.
  binaryCache = {
    host = "cache.neuros.is";
    node = "r440";
    port = 5080;
    publicKey = "r440-cache-1:8fh7/X6s7t2jRyhLZZRc6boWitD/RSJt2B9DxmF5Gj8=";
  };

  # kube-apiserver accepts tokens from authentik's provider `kubernetes`
  # (issuer = per-provider URL, trailing slash included), and the ID tokens
  # Headlamp forwards from the confidential provider `headlamp`. authentik's
  # issuer is per provider, so `headlamp` is a second issuer (with audience
  # `headlamp`), not just another audience of the first.
  oidc = {
    issuerUrl = "https://auth.neuros.is/application/o/kubernetes/";
    audiences = [ "kubernetes" ];
    extraIssuers = [
      {
        issuerUrl = "https://auth.neuros.is/application/o/headlamp/";
        audiences = [ "headlamp" ];
      }
    ];
  };

  secretsDir = "/var/lib/kubernetes/secrets";

  nodes = {
    c4130 = {
      system = "x86_64-linux";
      lanIP = "10.0.0.95";
      lanInterface = "eno1";
      tailnetIP = "100.74.71.16";
      sshHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUwlxfYy40XJz4tlWpAIyHjnK0lODwr/1kUgYfGElz7";
      roles = [
        "etcd"
        "controlPlane"
        "worker"
      ];
      gpu = true;
      cri = "containerd";
      keepalivedPriority = 150;
      labels = { };
      # Production vLLM owns both V100s. Only pods that tolerate this land
      # here (the NVIDIA device plugin and flannel do); opt a pod in with
      #   tolerations: [{ key: nvidia.com/gpu, operator: Equal,
      #                   value: vllm, effect: NoSchedule }]
      # plus runtimeClassName: nvidia and a nvidia.com/gpu resource limit
      # (only while vLLM is stopped: the GPUs are not shareable).
      taints.gpu = {
        key = "nvidia.com/gpu";
        value = "vllm";
        effect = "NoSchedule";
      };
      # Only the cluster ports on tailscale0 (vLLM 8000, LMCache UI 8081 and
      # Open WebUI 8082 are opened there by the host's own config).
      trustTailscale = false;
      extraSANs = [ ];
      # / is 96% full (17G free of 366G, 2026-10-31): with the upstream
      # defaults (nodefs.available<10%, imagefs.available<15%) the node
      # would sit in DiskPressure forever. Absolute thresholds instead.
      # Every signal is listed: a partial evictionHard zeroes the others.
      kubeletConfig = {
        evictionHard = {
          "memory.available" = "100Mi";
          "nodefs.available" = "5Gi";
          "nodefs.inodesFree" = "5%";
          "imagefs.available" = "5Gi";
          "imagefs.inodesFree" = "5%";
        };
        imageGCHighThresholdPercent = 98;
        imageGCLowThresholdPercent = 97;
      };
      rollout = {
        stage = "full";
        etcdPhase = "final";
        certSource = "sops";
      };
    };

    r440 = {
      system = "x86_64-linux";
      lanIP = "10.0.0.239";
      lanInterface = "eno1";
      tailnetIP = "100.81.238.37";
      sshHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKEBW4ZqM6suV2KILiqUgRSOiXs14BvUaZNp3fkE3AuG";
      roles = [
        "etcd"
        "controlPlane"
        "worker"
      ];
      gpu = false;
      cri = "containerd";
      keepalivedPriority = 100;
      labels = { };
      taints = { };
      extraSANs = [ ];
      rollout = {
        stage = "full";
        etcdPhase = "final";
        certSource = "files";
      };
    };

    m2mini = {
      system = "aarch64-linux";
      lanIP = "10.0.0.147";
      lanInterface = "end0";
      tailnetIP = "100.71.194.116";
      sshHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICzEbLMGd6J5cm5Gsxuvr/YOAk2PkrbUXS4w12HUFr7v";
      roles = [
        "etcd"
        "controlPlane"
        "worker"
      ];
      gpu = false;
      cri = "containerd";
      keepalivedPriority = 50;
      labels = { };
      taints = { };
      extraSANs = [ ];
      rollout = {
        stage = "full";
        etcdPhase = "final";
        certSource = "sops";
      };
    };
  };
}
