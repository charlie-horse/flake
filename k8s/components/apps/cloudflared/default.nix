# cloudflared: the cluster's ONE Cloudflare tunnel (cluster.tunnel, named
# `cluster`), namespace `cloudflared`. Every public hostname goes through it:
#
#   https://<host> -> Cloudflare edge -> cloudflared (any replica)
#     -> nginx sidecar on 127.0.0.1:9190 (same pod)
#     -> http://<service ClusterIP>:80 (cluster.<service>.serviceIP)
#        or, for the Nix cache (cluster.binaryCache), r440's LAN address
#        (nginx with basic auth in front of harmonia, hosts/r440/cache.nix)
#
#   files.nix       routes (hostname -> ClusterIP) and both config files
#   nginx.conf      the nginx sidecar's config (template)
#   configmap.nix   both files as a ConfigMap
#   deployment.nix  one replica per node, hostNetwork, cloudflared + nginx
#
# Why nginx: Cloudflare APPENDS the visitor's IP to a client-sent
# X-Forwarded-For, and authentik (and Open WebUI) read the leftmost entry.
# Cloudflare's edge always sets Cf-Connecting-Ip itself, so nginx REPLACES
# X-Forwarded-For / X-Real-IP with it. Websockets pass through.
#
# hostNetwork is why the namespace is `privileged` for Pod Security (see
# deployment.nix); the containers themselves run unprivileged, read-only
# and without capabilities.
#
# The tunnel credential: Secret cloudflared/tunnel-credentials, key
# credentials.json (the JSON `cloudflared tunnel create` writes),
# sops-encrypted in git (k8s/secrets/cloudflared/tunnel-credentials.sops.yaml)
# and applied by the Flux Kustomization `secrets` (k8s/README.md, "Secrets",
# "Cloudflare tunnel"); read at start. DNS: each hostname is a
# proxied CNAME to <tunnel id>.cfargotunnel.com:
#   cloudflared tunnel route dns --overwrite-dns <tunnel id> <hostname>
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
