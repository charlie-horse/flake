# r440's base system: Nix settings, host name, locale, logins, ssh and
# Tailscale.

{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [ ./hardware-configuration.nix ];

  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  #system.copySystemConfiguration = true;

  networking.hostName = "r440";
  networking.firewall.enable = true; # rules: ./firewall.nix
  networking.firewall.allowedTCPPorts = [
    22
  ];

  time.timeZone = "America/New_York";

  i18n.defaultLocale = "en_US.UTF-8";
  #console = {
  #  font = "Lat2-Terminus16";
  #  keyMap = "us";
  #  useXkbConfig = true; # use xkb.options in tty.
  #};

  # admin (modules/system/admin.nix) is the only login.
  custom.server.legacyCharlie.enable = false;

  environment.systemPackages = with pkgs; [
    neovim
  ];

  services.openssh.enable = true;
  # Tailscale (modules/server/tailscale.nix, which also turns on IP
  # forwarding). No tag is advertised: tag:node is set in the admin console.
  server.tailscale.advertiseRoutes = [ "10.0.1.0/24" ];

  # First NixOS version installed here; never change it (see
  # https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion).
  system.stateVersion = "26.05";
}
