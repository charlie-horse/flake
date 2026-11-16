# cloudflared: the cluster's ONE Cloudflare tunnel (cluster.tunnel, named
# `cluster`), namespace `cloudflared`. Every public hostname goes through it:
#
#   https://<host> -> Cloudflare edge -> cloudflared (any replica)
#     -> nginx sidecar on 127.0.0.1:9190 (same pod)
#     -> http://<service ClusterIP>:80, or r440's LAN address for the Nix cache
#
#   files.nix routes and both config files; nginx.conf the sidecar's config;
#   configmap.nix both as a ConfigMap; deployment.nix one replica per node
#
# nginx replaces X-Forwarded-For with Cf-Connecting-Ip. hostNetwork is why
# the namespace is `privileged`. Credential: Secret
# cloudflared/tunnel-credentials (sops). DNS routes and rotation:
# docs/k8s/apps.md#cloudflare-tunnel
{ ... }:
{
  imports = [
    ./configmap.nix
    ./deployment.nix
  ];

  validation.strict = true;

  resources.core.v1.Namespace.cloudflared.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "privileged";
    "pod-security.kubernetes.io/warn" = "baseline";
  };
}
