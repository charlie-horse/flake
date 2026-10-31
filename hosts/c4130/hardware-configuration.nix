{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot = {
       swraid.enable = true;
       swraid.mdadmConf = "ARRAY /dev/md/local_store metadata=1.2 UUID=c812bc1b:f3a1a49a:7a780185:703dcb3b";
       kernelParams = [ "nvidia.NVRM=0" ];
       kernelModules = [ "kvm-intel" "qla2xxx" ];
       extraModulePackages = [ ];
       initrd.kernelModules = [ ];
       initrd.availableKernelModules = [ "xhci_pci" "ehci_pci" "usbhid" "sd_mod" "qla2xxx" ];

       loader.systemd-boot.enable = true;
       loader.efi.canTouchEfiVariables = true;
  };

  swapDevices = [ ];
  fileSystems = {
      "/" = {
          device = "/dev/disk/by-label/C4130-ROOT";
          fsType = "ext4";
      };
      "/boot" = {
          device = "/dev/disk/by-label/C4130-BOOT";
          fsType = "vfat";
          options = [ "fmask=0022" "dmask=0022" ];
      };
  };

  hardware = {
      graphics.enable = true;
      enableRedistributableFirmware = true;
      cpu.intel.updateMicrocode = true;
      nvidia = {
          videoAcceleration = true;
          datacenter.enable = true;
          open = false;
      };
      nvidia-container-toolkit.enable = true;
      nvidia-container-toolkit.mount-nvidia-executables = true;
  };
  systemd.services.nvidia-fabricmanager.enable = lib.mkForce false;
  environment.systemPackages = [ pkgs.nvidia-container-toolkit ];
}
