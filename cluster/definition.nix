# Cluster definition: network, public services and nodes of the cluster.
#
# PURE DATA: no functions, no Nix paths, no secrets. Read by modules/cluster
# (via the `cluster` specialArg from lib/system/mkServer.nix),
# k8s/components/infra/cluster-pki/leaves.nix and k8s/. Keep the shape
# stable: add fields, don't rename them.
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

  # Name of the Tailscale Service (a tailnet-wide name served by several
  # nodes) that publishes the API server on the tailnet
  # (modules/cluster/tailscale-service.nix).
  apiserverTailscaleService = "kube-api";

  # Extra SANs (names a certificate is valid for) on every apiserver leaf
  # certificate; cert-manager re-issues on change. The Tailscale Service
  # name must be here, or kubectl fails TLS verification.
  apiserverExtraSANs = [ "kube-api.leaffish-monster.ts.net" ];

  # The single Cloudflare tunnel (locally managed: the ingress rules live in
  # k8s/components/apps/cloudflared/). Its credential is the Secret
  # cloudflared/tunnel-credentials, sops-encrypted in k8s/secrets/ (docs/secrets.md).
  tunnel = {
    name = "cluster";
    id = "59a275ca-be31-4f8d-99ce-c536eaf490f8";
  };

  # Public services: cloudflared -> its nginx sidecar -> http://<serviceIP>:80.
  # authentik (k8s/components/apps/authentik/).
  authentik = {
    host = "auth.neuros.is";
    serviceIP = "10.96.0.20";
  };

  # Headlamp (k8s/components/apps/headlamp.nix).
  headlamp = {
    host = "k8s.neuros.is";
    serviceIP = "10.96.0.21";
  };

  # Open WebUI (k8s/components/apps/open-webui.nix), chat front-end for
  # vLLM; logins through authentik.
  openWebui = {
    host = "chat.neuros.is";
    serviceIP = "10.96.0.22";
  };

  # Flux's webhook receiver (k8s/components/flux/), path /hook/ only.
  fluxWebhook = {
    host = "flux.neuros.is";
    serviceIP = "10.96.0.23";
  };

  # ATProto services, namespace `atproto` (k8s/components/apps/atproto/).
  # Tranquil PDS; logins through authentik.
  tranquilPds = {
    host = "pds.neuros.is";
    serviceIP = "10.96.0.24";
    # Handles are <name>.<handleDomain>; *.<handleDomain> routes to the PDS.
    handleDomain = "at.neuros.is";
    # did:web identities hosted by the PDS (did:web:<name>.<handleDomain>).
    # Owner of the Tangled knot and captain of the ATCR hold.
    adminDid = "did:web:charlie.at.neuros.is";
  };

  # Tangled knot (git hosting).
  tangledKnot = {
    host = "knot.neuros.is";
    serviceIP = "10.96.0.25";
  };

  # ATCR AppView (OCI registry API and web UI).
  atcr = {
    host = "cr.neuros.is";
    serviceIP = "10.96.0.27";
  };

  # ATCR hold (blob storage service).
  atcrHold = {
    host = "hold.neuros.is";
    serviceIP = "10.96.0.28";
  };

  # Minecraft
  minecraft = {
    cobblemon.host = "cobblemon.mc.neuros.is";
  };

  # The Nix binary cache on `node` (hosts/r440/cache.nix). Not a
  # Kubernetes Service: the tunnel forwards to the node's lanIP:port.
  # publicKey is the public half of the cache's signing key.
  binaryCache = {
    host = "cache.neuros.is";
    node = "r440";
    port = 5080;
    publicKey = "r440-cache-1:8fh7/X6s7t2jRyhLZZRc6boWitD/RSJt2B9DxmF5Gj8=";
  };

  # OIDC issuers whose tokens kube-apiserver accepts: authentik's provider
  # `kubernetes`, and provider `headlamp` for the ID tokens Headlamp
  # forwards. Each authentik provider is its own issuer, so `headlamp` must
  # be an extra issuer, not an extra audience. Keep the trailing slash.
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
      # vLLM uses both GPUs. Only pods that tolerate this taint run here
      # (the NVIDIA device plugin and flannel do); opt a pod in with
      #   tolerations: [{ key: nvidia.com/gpu, operator: Equal,
      #                   value: vllm, effect: NoSchedule }]
      # plus runtimeClassName: nvidia and a nvidia.com/gpu resource limit
      # (only while vLLM is stopped: the GPUs are not shareable).
      taints.gpu = {
        key = "nvidia.com/gpu";
        value = "vllm";
        effect = "NoSchedule";
      };
      # Open only the cluster ports on tailscale0; hosts/c4130/vllm opens
      # its own ports there.
      trustTailscale = false;
      extraSANs = [ ];
      # Absolute eviction thresholds: the upstream percentage defaults put
      # this node's small / in DiskPressure (kubelet evicts pods).
      # List every signal: a partial evictionHard zeroes the others.
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
      rollout.stage = "full";
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
      rollout.stage = "full";
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
      rollout.stage = "full";
    };
  };
}
