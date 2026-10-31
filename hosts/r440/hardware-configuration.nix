{ config, lib, pkgs, modulesPath, ... }:
{
	imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

	nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
	hardware.enableRedistributableFirmware = true;
	hardware.cpu.intel.updateMicrocode = true;

	boot = {
		initrd.availableKernelModules = [ "ahci" "xhci_pci" "usbhid" "sd_mod" ];
		initrd.kernelModules = [ ];
		loader.systemd-boot.enable = true;
		loader.efi.canTouchEfiVariables = true;
		kernelModules = [ "kvm-intel" "qla2xxx" ];
		kernelParams = [];
		extraModulePackages = [ ];
	};

	swapDevices = [ ];
	fileSystems = {
		"/boot" = {
			device = "/dev/disk/by-label/R440-BOOT";
			fsType = "vfat";
			options = [ "fmask=0022" "dmask=0022" ];
		};
		"/" = {
			device = "/dev/disk/by-label/R440-ROOT";
			fsType = "ext4";
		};
	};
}
