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

  # Caps the number of system generations. GRUB copies each generation's
  # kernel + initrd to the small /boot partition (/boot/kernels); without a
  # cap it fills up and a switch fails. configurationLimit caps the menu
  # entries (and so the kernels on /boot); the nix-gc pre-start deletes the
  # older profile generations before the daily GC, so their store paths
  # are collected too.
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
