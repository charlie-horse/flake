{ lib, ... }:
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

  # charlie (no password, not in wheel) and admin: modules/server/users.nix,
  # modules/system/admin.nix (users are immutable). m2mini only: charlie's
  # fixed uid and dialout. The old hash file /var/lib/secrets/charlie.passwd
  # is no longer read; delete it on m2mini after the switch. Never put a
  # plaintext `password = ...` here, in any form.
  users.users.charlie = {
    uid = 1000;
    group = "users";
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
