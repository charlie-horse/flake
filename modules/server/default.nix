# Baseline for every server host built with lib.system.<system>.mkServer
# (c4130, r440, m2mini).
{ pkgs, ... }:
{
  environment.systemPackages = [
    # /etc/nixos is a checkout of this flake on the servers.
    pkgs.git
    # Tunnel management (`cloudflared tunnel ...`); the tunnel service
    # itself is enabled per host (hosts/c4130/cloudflared.nix).
    pkgs.cloudflared
  ];
}
