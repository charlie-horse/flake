{
  config,
  lib,
  pkgs,
  ...
}:
{
  # md RAID (local_store, see hardware-configuration.nix): mdmonitor exits 1
  # without MAILADDR or PROGRAM. There is no MTA here, so
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

  # Tailscale (modules/server/tailscale.nix): exit node + 10.0.1.0/24, tag:node.
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
