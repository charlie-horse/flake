# authentik server and worker from the authentik Helm chart
# (charts.authentik, image ghcr.io/goauthentik/server). The chart's bundled
# postgresql subchart is off (postgres.nix runs our own).
{
  lib,
  pkgs,
  catenix,
  charts,
  cluster,
  k8sLib,
  kubeVersion,
  ...
}:
let
  inherit (import ./settings.nix) namespace secretName blueprintsConfigMap db;

  # Scheduling, sizing and hardening shared by server and worker. The image
  # runs as `authentik` (uid 1000), so both meet `restricted`.
  common = {
    # One per node (with the "hard" anti-affinity below).
    replicas = lib.length (lib.attrNames cluster.nodes);
    # One per node leaves no node for a surge pod, and the old pod would
    # never go: replace one at a time instead.
    deploymentStrategy = {
      type = "RollingUpdate";
      rollingUpdate = {
        maxSurge = 0;
        maxUnavailable = 1;
      };
    };
    # Every node's taints (c4130: nvidia.com/gpu=vllm), so one lands on each.
    tolerations = k8sLib.nodeTolerations;
    securityContext = {
      runAsNonRoot = true;
      seccompProfile.type = "RuntimeDefault";
    };
    containerSecurityContext = {
      allowPrivilegeEscalation = false;
      capabilities.drop = [ "ALL" ];
    };
    resources = {
      requests = {
        cpu = "100m";
        memory = "512Mi";
      };
      limits.memory = "1536Mi";
    };
  };

  # Honour X-Forwarded-For/-Proto only from the tunnel's proxies: the
  # in-cluster cloudflared + nginx (apps/cloudflared) run with hostNetwork on
  # every node, so they reach the ClusterIP from that node's cni0
  # (10.244.N.1) or flannel.1 (10.244.N.0) address (node podCIDRs: r440 .0,
  # c4130 .1, m2mini .2), plus the nodes' LAN IPs and loopback for the
  # healthchecks. Ordinary pods get .2 and up, so they cannot forge client
  # IPs (authentik's default trusts all of 10/8). -Proto must stay trusted
  # from the proxies, or the issuer would be http://.
  trustedProxies =
    [
      "10.244.0.0/31"
      "10.244.1.0/31"
      "10.244.2.0/31"
      "127.0.0.1/32"
      "::1/128"
    ]
    ++ map (n: "${n.lanIP}/32") (lib.attrValues cluster.nodes);
in
{
  imports = [
    (catenix.importChart {
      inherit pkgs kubeVersion;
      chart = charts.authentik;
      release = {
        name = "authentik";
        inherit namespace;
      };
      patch = k8sLib.fixedServiceIP {
        service = "authentik-server";
        ip = cluster.authentik.serviceIP;
      };
      values = {
        global.env = lib.mapAttrsToList (name: value: { inherit name value; }) {
          AUTHENTIK_POSTGRESQL__HOST = db.name;
          AUTHENTIK_POSTGRESQL__NAME = db.database;
          AUTHENTIK_POSTGRESQL__USER = db.user;
          AUTHENTIK_LOG_LEVEL = "info";
          AUTHENTIK_ERROR_REPORTING__ENABLED = "false";
          AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS = lib.concatStringsSep "," trustedProxies;
        };
        # Only secrets live there; everything else is global.env above.
        authentik.existingSecret.secretName = secretName;
        blueprints.configMaps = [ blueprintsConfigMap ];
        postgresql.enabled = false;
        # Required anti-affinity on kubernetes.io/hostname: one per node.
        global.affinity.podAntiAffinity = "hard";
        server = common;
        worker = common;
      };
    })
  ];
}
