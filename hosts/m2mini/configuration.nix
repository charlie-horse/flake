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

  # Logins: admin (modules/system/admin.nix, via modules/server), plus
  # charlie while custom.server.legacyCharlie.enable is on (stage 1 of
  # docs/cluster.md, "Removing charlie from the servers"; mutable users,
  # modules/server/legacy-charlie.nix). Stage 1 keeps charlie exactly as he
  # was before the sops switch (uid 1000, wheel, dialout; fish in
  # ./shell.nix, Nix trust in ./nix.nix), minus the hashedPasswordFile:
  # with mutable users it only applied when charlie was created, so his
  # /etc/shadow entry is unchanged. Once legacyCharlie is off, charlie is
  # gone and what is still wanted is admin's: dialout (serial adapters)
  # here, fish and Nix trust. charlie's uid 1000 then stays reserved in
  # /var/lib/nixos/uid-map; admin keeps its own uid. The old hash file
  # /var/lib/secrets/charlie.passwd is unused; delete it in stage 2. Never
  # put a plaintext `password = ...` here, in any form.
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
