# Cloudflare tunnel `solaris-auth`, dedicated to authentik:
#   https://auth.neuros.is -> Service authentik/authentik-server at its fixed
#   ClusterIP (cluster/definition.nix: authentik.serviceIP), through this
#   node's kube-proxy. authentik's pods run on r440 (amd64; c4130 is
#   tainted), so SSO does not depend on c4130.
# Separate from c4130's chat tunnel on purpose: its own credential, its own
# DNS route, nothing else routed through it.
#
# The credential (the JSON `cloudflared tunnel create` writes) is a runtime
# secret referenced by a STRING path, never in the Nix store or git. It was
# installed root-only (2026-11-10):
#   sudo install -D -m 0400 -o root -g root <tunnel>.json \
#     /var/lib/secrets/cloudflared/<tunnel>.json
# DNS (once, with an account cert from `cloudflared tunnel login`; charlie's
# is in c4130:~/.cloudflared/cert.pem):
#   cloudflared tunnel route dns --overwrite-dns <tunnel> auth.neuros.is
{ cluster, ... }:
let
  tunnel = "cac462c4-7420-4ff3-9a40-c090a4e18737";
in
{
  services.cloudflared = {
    enable = true;
    tunnels.${tunnel} = {
      credentialsFile = "/var/lib/secrets/cloudflared/${tunnel}.json";
      default = "http_status:404";
      ingress.${cluster.authentik.host} = "http://${cluster.authentik.serviceIP}:80";
    };
  };
}
