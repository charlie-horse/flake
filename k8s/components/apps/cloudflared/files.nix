# The two configuration files of the cloudflared pods, built from
# cluster/definition.nix: cloudflared's own config (the locally managed
# tunnel's ingress rules) and the nginx sidecar's (nginx.conf template).
# A plain function, used by configmap.nix and deployment.nix.
{ lib, cluster }:
rec {
  proxyPort = 9190;
  metricsPort = 20250;

  # Public hostname -> upstream (fixed ClusterIPs). Add a service here (and
  # its DNS route, k8s/README.md) to publish it.
  routes = lib.listToAttrs (
    map (s: lib.nameValuePair cluster.${s}.host "${cluster.${s}.serviceIP}:80") [
      "authentik"
      "headlamp"
      "openWebui"
      "fluxWebhook"
    ]
  );

  # cloudflared sends every hostname to the nginx sidecar. JSON is YAML.
  cloudflared = builtins.toJSON {
    tunnel = cluster.tunnel.id;
    credentials-file = "/etc/cloudflared/credentials/credentials.json";
    metrics = "127.0.0.1:${toString metricsPort}";
    no-autoupdate = true;
    ingress =
      map (host: {
        hostname = host;
        service = "http://127.0.0.1:${toString proxyPort}";
      }) (lib.attrNames routes)
      ++ [ { service = "http_status:404"; } ];
  };

  nginx =
    lib.replaceStrings
      [
        "@ROUTES@"
        "@HOOK_HOST_REGEX@"
        "@PROXY_PORT@"
      ]
      [
        (lib.concatStringsSep "\n" (lib.mapAttrsToList (h: u: "    ${h} ${u};") routes))
        (lib.escapeRegex cluster.fluxWebhook.host)
        (toString proxyPort)
      ]
      (builtins.readFile ./nginx.conf);
}
