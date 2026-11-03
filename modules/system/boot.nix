{ lib, config, ... }: let
    inherit (lib)
        mkIf
        types
        mkMerge
        mkOption
	mkOverride
        mkDefault;
    inherit (config.custom)
        bootMode;
in {
    options.custom = {
        bootMode = mkOption {
            type = types.enum [ "legacy" "uefi" ];
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

        services.journald.extraConfig = "SystemMaxUse=500M";
    };
}
