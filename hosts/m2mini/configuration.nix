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

  # The only login is admin (modules/system/admin.nix, via modules/server;
  # users are immutable). charlie was removed from the servers in 2026-11
  # (docs/cluster.md, "Removing charlie from the servers"); what it had
  # here that is still wanted moved to admin: dialout (serial adapters)
  # here, fish in ./shell.nix, Nix trust in ./nix.nix. charlie's fixed uid
  # 1000 stays reserved in /var/lib/nixos/uid-map, so admin keeps its own
  # uid. The old hash file /var/lib/secrets/charlie.passwd is unused;
  # delete it. Never put a plaintext `password = ...` here, in any form.
  users.users.admin.extraGroups = [ "dialout" ];

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
