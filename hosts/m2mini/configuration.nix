{ config, lib, ... }:
{
  # The apple-silicon module is imported by the flake
  # (inputs.apple-silicon-m2mini); peripheral firmware: ./firmware.nix.
  hardware.asahi = {
    enable = true;
    avd.enable = false;
  };

  networking.hostName = "m2mini";
  networking.networkmanager.enable = false;

  time.timeZone = lib.mkDefault "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # admin is the only login; charlie's block applies only with
  # legacyCharlie on. Never put a plaintext `password = ...` here.
  custom.server.legacyCharlie.enable = false;

  users.users.admin.extraGroups = [ "dialout" ];
  users.users.charlie = lib.mkIf config.custom.server.legacyCharlie.enable {
    uid = 1000;
    group = "users";
    # wheel: modules/server/legacy-charlie.nix.
    extraGroups = [ "dialout" ];
  };

  services.openssh.enable = true;
  networking.firewall.allowedTCPPorts = [
    22
  ];

  # Tailscale (modules/server/tailscale.nix, which also turns on IP
  # forwarding). No tag is advertised: tag:node is set in the admin console.
  server.tailscale.advertiseRoutes = [ "10.0.0.0/16" ];

  system.stateVersion = "26.05";
}
