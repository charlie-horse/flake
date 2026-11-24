# Baseline for every server host built with lib.system.<system>.mkServer.
{ config, pkgs, ... }:
{
  # Tailscale prefs and autoconnect; per-host values (routes, tags) are
  # server.tailscale.* in each host's configuration.nix.
  imports = [
    ./tailscale.nix
    # The flake's binary cache as a substituter (custom.nixCache.*).
    # Shared with the desktops, which get modules/system wholesale.
    ../system/nix-cache.nix
    # sops-nix (secrets/<host>.yaml, secrets/common.yaml) and the admin
    # account (wheel). The desktops get both with modules/ wholesale, plus
    # their own user (modules/system/user.nix). Host-specific admin
    # settings live in the host's directory.
    ../system/sops.nix
    ../system/admin.nix
    # Authentication policy (sshd keys only, sudo, polkit, console; the
    # hardware factor): one module for every host, docs/auth.md.
    ../system/auth
    # The ssh client (cluster Host block, known host keys), shared with the
    # desktops.
    ../programs/ssh.nix
    # custom.server.legacyCharlie.enable: an extra `charlie` login; off,
    # admin is the only login, users are immutable and root is locked.
    ./legacy-charlie.nix
  ];

  # No local ssh-agent: ssh and sudo (pam_rssh) must use the agent
  # forwarded from the client, and a local agent would shadow it.
  programs.ssh.startAgent = false;

  # nixpkgs' newest Nix, the same release line as the desktops.
  nix.package = pkgs.nixVersions.latest;

  environment.systemPackages = [
    # /etc/nixos is a checkout of this flake on the servers.
    pkgs.git
    # Tunnel management (`cloudflared tunnel ...`); hosts enable the tunnel
    # service themselves.
    pkgs.cloudflared
  ];

  # Re-owns all of /etc/nixos (the git checkout of this flake) to
  # admin:users (charlie:root with legacyCharlie on) at every boot and
  # switch; git refuses a repository owned by another user. `Z` changes
  # symlinks themselves, never their targets; `-` leaves modes alone. Does
  # nothing if /etc/nixos is missing.
  systemd.tmpfiles.settings."10-etc-nixos"."/etc/nixos".Z = {
    user = if config.custom.server.legacyCharlie.enable then "charlie" else "admin";
    group = if config.custom.server.legacyCharlie.enable then "root" else "users";
    mode = "-";
  };
}
