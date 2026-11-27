# nether's base system: Nix settings, locale, logins, network and
# Tailscale.
{ pkgs, ... }:
{
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # One NIC, IPv4 by DHCP from the provider.
  networking.useDHCP = true;

  # Nothing is open on the public address. tailscaled's WireGuard port
  # allows direct (non-relayed) tailnet connections.
  networking.firewall = {
    enable = true;
    allowedUDPPorts = [ 41641 ];
  };

  # sshd for the host key and ssh from the tailnet; port 22 stays closed on
  # the public address. Tailscale SSH (modules/server/tailscale.nix) is the
  # way in.
  services.openssh = {
    enable = true;
    openFirewall = false;
  };

  # admin (modules/system/admin.nix) is the only login.
  custom.server.legacyCharlie.enable = false;

  environment.systemPackages = [ pkgs.neovim ];

  # First NixOS version installed here; never change it (see
  # https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion).
  system.stateVersion = "26.05";
}
