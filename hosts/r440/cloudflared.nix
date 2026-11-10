# Cloudflare tunnel `solaris-auth`, dedicated to authentik (and Headlamp):
#
#   https://auth.neuros.is
#     -> cloudflared (this tunnel)
#     -> nginx on 127.0.0.1:9180 (below: fixes the client-IP headers)
#     -> Service authentik/authentik-server at its fixed ClusterIP
#        (cluster/definition.nix: authentik.serviceIP), via kube-proxy
#
#   https://k8s.neuros.is
#     -> cloudflared (this tunnel)
#     -> Service headlamp/headlamp at its fixed ClusterIP
#        (cluster/definition.nix: headlamp.serviceIP), via kube-proxy
#   (no nginx: Headlamp does not act on client IPs; cloudflared passes its
#   websockets through as is)
#
# authentik's and Headlamp's pods run on r440 (amd64; c4130 is tainted), so
# SSO does not depend on c4130. Separate from c4130's chat tunnel on purpose:
# its own credential, its own DNS routes, nothing else routed through it.
#
# Why nginx: Cloudflare *appends* the visitor's IP to any X-Forwarded-For
# the visitor sent, and authentik reads the leftmost entry, so a client
# could choose the IP authentik logs and applies policies to. Cloudflare's
# edge always sets Cf-Connecting-Ip itself (a client cannot forge it), so
# nginx REPLACES X-Forwarded-For/X-Real-IP with it. The tunnel is locally
# managed (this file), so this cannot be done in the Zero Trust dashboard; a
# zone Transform Rule would also work but is not needed with this.
# authentik trusts X-Forwarded-* only from r440's own addresses
# (AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS in k8s/components/authentik.nix),
# which is where nginx's connections come from. nginx listens on loopback
# only, so nothing but cloudflared reaches it.
#
# The credential (the JSON `cloudflared tunnel create` writes) is a runtime
# secret referenced by a STRING path, never in the Nix store or git. It was
# installed root-only (2026-11-10):
#   sudo install -D -m 0400 -o root -g root <tunnel>.json \
#     /var/lib/secrets/cloudflared/<tunnel>.json
# DNS (once, with an account cert from `cloudflared tunnel login`; charlie's
# is in c4130:~/.cloudflared/cert.pem):
#   cloudflared tunnel route dns --overwrite-dns <tunnel> auth.neuros.is
#   cloudflared tunnel route dns --overwrite-dns <tunnel> k8s.neuros.is
{ cluster, ... }:
let
  tunnel = "cac462c4-7420-4ff3-9a40-c090a4e18737";
  proxyPort = 9180;
in
{
  services.cloudflared = {
    enable = true;
    tunnels.${tunnel} = {
      credentialsFile = "/var/lib/secrets/cloudflared/${tunnel}.json";
      default = "http_status:404";
      ingress = {
        ${cluster.authentik.host} = "http://127.0.0.1:${toString proxyPort}";
        ${cluster.headlamp.host} = "http://${cluster.headlamp.serviceIP}:80";
      };
    };
  };

  services.nginx = {
    enable = true;
    # Not recommendedProxySettings: it APPENDS to X-Forwarded-For, which is
    # exactly what must not happen here.
    appendHttpConfig = ''
      # The visitor's IP as Cloudflare's edge saw it; loopback if absent
      # (only possible for a request that did not come through Cloudflare).
      map $http_cf_connecting_ip $authentik_client_ip {
        ""      $remote_addr;
        default $http_cf_connecting_ip;
      }
      map $http_x_forwarded_proto $authentik_proto {
        ""      https;
        default $http_x_forwarded_proto;
      }
    '';
    virtualHosts.authentik-tunnel = {
      default = true;
      serverName = cluster.authentik.host;
      listen = [
        {
          addr = "127.0.0.1";
          port = proxyPort;
        }
      ];
      locations."/" = {
        proxyPass = "http://${cluster.authentik.serviceIP}:80";
        # Upgrade/Connection for authentik's websockets (flows, outposts).
        proxyWebsockets = true;
        extraConfig = ''
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-For $authentik_client_ip;
          proxy_set_header X-Real-IP $authentik_client_ip;
          proxy_set_header X-Forwarded-Proto $authentik_proto;
          proxy_set_header X-Forwarded-Host $host;
          proxy_read_timeout 300s;
          proxy_buffering off;
          client_max_body_size 64m;
        '';
      };
    };
  };
}
