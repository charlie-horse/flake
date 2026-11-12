# Baseline for every server host built with lib.system.<system>.mkServer
# (c4130, r440, m2mini).
{ pkgs, ... }:
{
  # Tailscale prefs and autoconnect; per-host values (routes, tags) are
  # server.tailscale.* in each host's configuration.nix.
  imports = [
    ./tailscale.nix
    # r440's binary cache as a substituter (custom.nixCache.*, per host).
    # Shared with the desktops, which get modules/system wholesale.
    ../system/nix-cache.nix
  ];

  environment.systemPackages = [
    # /etc/nixos is a checkout of this flake on the servers.
    pkgs.git
    # Tunnel management (`cloudflared tunnel ...`); the tunnel service
    # itself is enabled per host (hosts/c4130/cloudflared.nix).
    pkgs.cloudflared
  ];
}
