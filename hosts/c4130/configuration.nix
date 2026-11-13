{
  config,
  lib,
  pkgs,
  ...
}:
{
  # md RAID (local_store, see hardware-configuration.nix): since nixos-26.05
  # mdmonitor exits 1 without MAILADDR or PROGRAM. There is no MTA here, so
  # md events (Fail, DegradedArray, ...) go to the journal instead:
  # journalctl -t mdadm.
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
  # Cluster ports (etcd 2379/2380, apiserver 6443, kubelet, flannel VXLAN
  # 8472/udp) are opened by modules/cluster, to the cluster nodes only.
  networking.firewall.allowedTCPPorts = [
    22
    80
    443
  ];
  # IP forwarding (v4 and v6) comes from modules/server/tailscale.nix
  # (useRoutingFeatures = "server") and the kubelet module.

  # Tailscale (modules/server/tailscale.nix). Live prefs 2026-11-12: exit
  # node + 10.0.1.0/24, AdvertiseTags [ tag:node ].
  server.tailscale = {
    advertiseRoutes = [ "10.0.1.0/24" ];
    advertiseTags = [ "tag:node" ];
  };
  services.openssh.enable = true;

  users.groups.video = { };
  # Logins: admin (modules/system/admin.nix), plus charlie (wheel, as
  # before the sops switch) while custom.server.legacyCharlie.enable is on
  # (modules/server/legacy-charlie.nix); both via modules/server.

  environment.systemPackages = with pkgs; [
    pciutils
    btop-cuda
    neovim
    sysfsutils
  ];

  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "26.05"; # Did you read the comment?

}
