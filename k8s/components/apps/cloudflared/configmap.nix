# cloudflared's and nginx's configuration files (files.nix).
{ lib, cluster, ... }:
let
  files = import ./files.nix { inherit lib cluster; };
in
{
  resources.core.v1.ConfigMap.cloudflared = {
    metadata.namespace = "cloudflared";
    data = {
      "config.yaml" = files.cloudflared;
      "nginx.conf" = files.nginx;
    };
  };
}
