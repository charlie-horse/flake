# Cloudflare tunnel: https://chat.neuros.is -> Open WebUI (localhost:8082).
# (auth.neuros.is has its own tunnel, on r440: hosts/r440/cloudflared.nix.)
#
# The tunnel credential (the JSON `cloudflared tunnel create` writes) is a
# runtime secret: it is referenced by a STRING path, so it never enters the
# Nix store. systemd hands it to the unit with LoadCredential. Install it
# (root-only) before switching:
#   sudo install -D -m 0400 -o root -g root \
#     ~/.cloudflared/536d3af9-2b33-4ce7-b5d6-b5848f835fe6.json \
#     /var/lib/secrets/cloudflared/536d3af9-2b33-4ce7-b5d6-b5848f835fe6.json
# The account cert for managing tunnels (`cloudflared tunnel login`) is not
# needed by the service; it stays in charlie's ~/.cloudflared/cert.pem.
{ ... }:
let
  tunnel = "536d3af9-2b33-4ce7-b5d6-b5848f835fe6";
in
{
  services.cloudflared = {
    enable = true;
    tunnels.${tunnel} = {
      credentialsFile = "/var/lib/secrets/cloudflared/${tunnel}.json";
      default = "http_status:404";
      ingress."chat.neuros.is" = "http://localhost:8082";
    };
  };
}
