{
  lib,
  config,
  options,
  ...
}:
let
  inherit (lib)
    mkIf
    types
    mkMerge
    mkOption
    mkOverride
    mkDefault
    ;
  inherit (config.custom)
    bootMode
    ;
in
{
  options.custom = {
    bootMode = mkOption {
      type = types.enum [
        "legacy"
        "uefi"
      ];
      default = "uefi";
    };
    swapSize = mkOption {
      type = types.str;
      default = "0";
    };
  };

  config = {
    hardware.enableAllFirmware = true;
    hardware.enableRedistributableFirmware = true;

    fileSystems."/boot/efi" = mkIf (bootMode == "uefi") {
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

    boot.initrd.availableKernelModules = mkDefault [
      "nvme"
      "xhci_pci"
      "ahci"
      "usbhid"
      "sd_mod"
    ];
    boot.loader = mkMerge [
      { timeout = 1; }
      (mkIf (bootMode == "uefi") (mkDefault {
        efi.canTouchEfiVariables = true;
        efi.efiSysMountPoint = "/boot/efi";
        systemd-boot = {
          enable = true;
          consoleMode = "max";
          editor = false;
        };
      }))
      (mkIf (bootMode == "legacy") {
        grub.enable = true;
        grub.devices = [ "/dev/sdd" ];
      })
    ];

    # nixos-unstable replaced services.journald.extraConfig with
    # settings.Journal (setting extraConfig is now an error). Both branches
    # until flake.lock's nixpkgs-unstable has settings; then keep that one.
    services.journald =
      if options.services.journald ? settings then
        { settings.Journal.SystemMaxUse = "500M"; }
      else
        { extraConfig = "SystemMaxUse=500M"; };
  };
}
