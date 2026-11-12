{ lib, config, ... }:
let
  inherit (lib)
    mkIf
    types
    mkMerge
    mkOption
    mkOverride
    mkDefault
    ;
in
{
  hardware.enableAllFirmware = true;
  hardware.enableRedistributableFirmware = true;

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/BOOT";
    fsType = "vfat";
    options = [ "umask=0022" ];
  };
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  #swapDevices = mkDefault [{
  #    device = "/dev/disk/by-label/swap";
  #}];

  # At most 5 system generations. /boot is a 499 MB vfat partition and GRUB
  # copies each generation's Asahi kernel + initrd there (/boot/kernels), so
  # unbounded generations eventually fill it and a switch fails (77% used
  # with 9 generations on 2026-11-12). configurationLimit caps the menu
  # entries (and so the kernels kept on /boot); the nix-gc pre-start deletes
  # profile generations beyond the newest 5 before the daily GC, so their
  # closures are collected too.
  boot.loader.grub.configurationLimit = 5;
  systemd.services.nix-gc.preStart = ''
    ${config.nix.package}/bin/nix-env -p /nix/var/nix/profiles/system --delete-generations +5
  '';

  services.journald.extraConfig = "SystemMaxUse=500M";
  boot.loader.timeout = 1;
  boot.loader.efi.efiSysMountPoint = "/boot";
  boot.initrd.availableKernelModules = mkDefault [
    "nvme"
    "xhci_pci"
    "ahci"
    "usbhid"
    "sd_mod"
  ];

}
