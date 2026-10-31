{ config, lib, pkgs, unstable, ... }:
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
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
  # net.ipv4.ip_forward = 1 comes from the kubelet module (modules/cluster);
  # a second definition here would be an eval error.
  boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;

  services.tailscale.enable = true;
  services.openssh.enable = true;
  systemd.services.tailscaled.serviceConfig.Environment = [ 
    "TS_DEBUG_FIREWALL_MODE=nftables" 
  ];

  users.groups.video = {};
  users.users.charlie = {
    isNormalUser = true;
    extraGroups = [ "wheel" ]; # Enable ‘sudo’ for the user.
    packages = with pkgs; [
    ];
  };

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

