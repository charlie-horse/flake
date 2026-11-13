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
    # charlie next to admin, mutable users, root untouched until
    # custom.server.legacyCharlie.enable is turned off; then admin is the
    # only login and root is locked (docs/cluster.md, "Removing charlie
    # from the servers").
    ./legacy-charlie.nix
  ];

  # No local ssh-agent: on a server, ssh and sudo (pam_rssh) use the agent
  # forwarded from the client; a local, empty agent would take its place
  # whenever none is forwarded.
  programs.ssh.startAgent = false;

  environment.systemPackages = [
    # /etc/nixos is a checkout of this flake on the servers.
    pkgs.git
    # Tunnel management (`cloudflared tunnel ...`); the tunnel service
    # itself is enabled per host (hosts/c4130/cloudflared.nix).
    pkgs.cloudflared
  ];

  # /etc/nixos (the git checkout of this flake) belongs to the account that
  # pulls it: git refuses a repository owned by another user ("dubious
  # ownership"), so a wrong owner leaves the host un-pullable. That is
  # charlie while custom.server.legacyCharlie.enable is on (stage 1:
  # charlie is still the operating account and the fallback if admin does
  # not work, and the tree stays as it was before the sops switch), admin
  # once it is off (stage 2; the runbook re-owns the tree to admin by hand
  # before that pull, and this rule keeps it so). A rollback across the
  # flip re-owns it back. `Z` re-owns the whole tree (symlinks themselves,
  # never their targets; modes untouched, `-`) at every boot and every
  # switch (systemd-tmpfiles-resetup runs on each activation), which also
  # repairs root-owned files left by a `sudo git ...`. The tree is a few
  # MB, so the walk is cheap. Does nothing if /etc/nixos is missing.
  systemd.tmpfiles.settings."10-etc-nixos"."/etc/nixos".Z = {
    user = if config.custom.server.legacyCharlie.enable then "charlie" else "admin";
    group = "root";
    mode = "-";
  };
}
