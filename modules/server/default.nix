# Baseline for every server host built with lib.system.<system>.mkServer
# (c4130, r440, m2mini).
{ config, pkgs, ... }:
{
  # Tailscale prefs and autoconnect; per-host values (routes, tags) are
  # server.tailscale.* in each host's configuration.nix.
  imports = [
    ./tailscale.nix
    # r440's binary cache as a substituter (custom.nixCache.*, per host).
    # Shared with the desktops, which get modules/system wholesale.
    ../system/nix-cache.nix
    # sops-nix (secrets/<host>.yaml, secrets/common.yaml) and the admin
    # account (wheel). The desktops get both with modules/ wholesale, plus
    # their own user (modules/system/user.nix, charlie on Famine).
    # Host-specific admin bits (m2mini: dialout, fish) are in the host.
    ../system/sops.nix
    ../system/admin.nix
    # Authentication policy (sshd keys only, sudo, polkit, console; the
    # hardware factor): one module for every host, docs/auth.md.
    ../system/auth
    # The ssh client (cluster Host block, known host keys), shared with the
    # desktops.
    ../programs/ssh.nix
    # custom.server.legacyCharlie.enable (off on every server): admin is the
    # only login, users are immutable, root is locked.
    ./legacy-charlie.nix
  ];

  # No local ssh-agent: on a server, ssh and sudo (pam_rssh) use the agent
  # forwarded from the client; a local, empty agent would take its place
  # whenever none is forwarded.
  programs.ssh.startAgent = false;

  # nixpkgs' newest Nix, the release line the desktops get from
  # nixpkgs-unstable.
  nix.package = pkgs.nixVersions.latest;

  environment.systemPackages = [
    # /etc/nixos is a checkout of this flake on the servers.
    pkgs.git
    # Tunnel management (`cloudflared tunnel ...`); the tunnel service
    # itself is enabled per host (hosts/c4130/cloudflared.nix).
    pkgs.cloudflared
  ];

  # Every file and folder in /etc/nixos (the git checkout of this flake) is
  # owned by admin:users (charlie with legacyCharlie on): git refuses a
  # repository owned by another user ("dubious ownership"). `Z` re-owns the
  # whole tree (symlinks themselves, never their targets; modes untouched,
  # `-`) at every boot and every switch, which also repairs root-owned files
  # left by a `sudo git ...`. Does nothing if /etc/nixos is missing.
  systemd.tmpfiles.settings."10-etc-nixos"."/etc/nixos".Z = {
    user = if config.custom.server.legacyCharlie.enable then "charlie" else "admin";
    group = if config.custom.server.legacyCharlie.enable then "root" else "users";
    mode = "-";
  };
}
