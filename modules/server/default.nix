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
    # sops-nix (secrets/<host>.yaml, secrets/common.yaml) and the only
    # local login: admin (wheel), root locked. The desktops get both with
    # modules/ wholesale, plus their own user (modules/system/user.nix,
    # charlie on Famine). The servers have no other login account since
    # 2026-11 (docs/cluster.md, "Removing charlie from the servers");
    # host-specific admin bits (m2mini: dialout, fish) are in the host.
    ../system/sops.nix
    ../system/admin.nix
  ];

  environment.systemPackages = [
    # /etc/nixos is a checkout of this flake on the servers.
    pkgs.git
    # Tunnel management (`cloudflared tunnel ...`); the tunnel service
    # itself is enabled per host (hosts/c4130/cloudflared.nix).
    pkgs.cloudflared
  ];

  # /etc/nixos (the git checkout of this flake) belongs to admin, the
  # account that pulls it: git refuses a repository owned by another user
  # ("dubious ownership"), so a wrong owner leaves the host un-pullable.
  # `Z` re-owns the whole tree (symlinks themselves, never their targets;
  # modes untouched, `-`) at every boot and every switch
  # (systemd-tmpfiles-resetup runs on each activation). This fixes the
  # checkout once after charlie's removal, and again whenever something
  # run as root (e.g. a `sudo git ...`) leaves root-owned files in it. The
  # tree is a few MB, so the walk is cheap. Does nothing if /etc/nixos is
  # missing.
  systemd.tmpfiles.settings."10-etc-nixos"."/etc/nixos".Z = {
    user = "admin";
    group = "root";
    mode = "-";
  };
}
