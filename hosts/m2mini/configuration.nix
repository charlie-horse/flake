{ config, lib, ... }:
{
  # Ported from m2mini:/etc/nixos/m2mini.nix. The apple-silicon module is
  # imported by the flake (inputs.apple-silicon-m2mini), the peripheral
  # firmware is handled in ./firmware.nix.
  hardware.asahi = {
    enable = true;
    avd.enable = false;
  };

  networking.hostName = "m2mini";
  networking.networkmanager.enable = false;

  time.timeZone = lib.mkDefault "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # Stage 2 of the charlie removal: admin is the only login. charlie's
  # block below only applies with legacyCharlie on (stage 1). Never put a
  # plaintext `password = ...` here. docs/hosts/m2mini.md#shell-and-accounts
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
  # forwarding). Live prefs 2026-11-12: exit node + 10.0.0.0/16; tag:node
  # was set in the admin console, so no tag is advertised.
  server.tailscale.advertiseRoutes = [ "10.0.0.0/16" ];

  system.stateVersion = "26.05";
}
