{ lib, ... }: let
    inherit (lib)
        mkIf
        types
        mkMerge
        mkOption
        mkOverride
        mkDefault;
in {
    hardware.enableAllFirmware = true;
    hardware.enableRedistributableFirmware = true;

    fileSystems."/boot" = {
        device  = "/dev/disk/by-label/BOOT";
        fsType  = "vfat";
        options = [ "umask=0022" ];
    };
    fileSystems."/" = {
        device = "/dev/disk/by-label/nixos";
        fsType = "ext4";
    };
    #swapDevices = mkDefault [{
    #    device = "/dev/disk/by-label/swap";
    #}];

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
