{
  config,
  lib,
  pkgs,
  ...
}:
{
  # Logs md RAID events (Fail, DegradedArray, ...) for local_store
  # (hardware-configuration.nix) to the journal: journalctl -t mdadm.
  # mdmonitor exits 1 without MAILADDR or PROGRAM; this host has no mail.
  boot.swraid.mdadmConf = ''
    PROGRAM ${pkgs.writeShellScript "mdadm-event-log" ''
      exec ${pkgs.util-linux}/bin/logger -t mdadm -p daemon.warning -- "md event: $*"
    ''}
  '';

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  nixpkgs.config.allowUnfree = true;

  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";
  networking.hostName = "c4130";
  networking.firewall.enable = true;
  # modules/cluster opens the cluster ports, to the cluster nodes only.
  networking.firewall.allowedTCPPorts = [
    22
    80
    443
  ];
  # IP forwarding (v4 and v6) comes from modules/server/tailscale.nix
  # (useRoutingFeatures = "server") and the kubelet module.

  # Tailscale options: modules/server/tailscale.nix.
  server.tailscale = {
    advertiseRoutes = [ "10.0.1.0/24" ];
    advertiseTags = [ "tag:node" ];
  };
  services.openssh.enable = true;

  users.groups.video = { };
  # Off: admin (modules/system/admin.nix) is the only login
  # (modules/server/legacy-charlie.nix).
  custom.server.legacyCharlie.enable = false;

  environment.systemPackages = with pkgs; [
    pciutils
    btop-cuda
    neovim
    sysfsutils
  ];

  # system.copySystemConfiguration = true;

  # First NixOS release installed here; keeps stateful data compatible.
  # Never change it without migrating that data by hand (see
  # https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion).
  system.stateVersion = "26.05"; # Did you read the comment?

}
