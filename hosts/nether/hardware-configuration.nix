# KVM guest with virtio devices, BIOS boot. The disk layout is
# modules/server/vps-disk.nix (disko).
{ modulesPath, ... }:
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../../modules/server/vps-disk.nix
  ];

  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_scsi"
    "virtio_blk"
    "virtio_net"
    "sd_mod"
  ];
  # GRUB in BIOS mode; disko sets the install disk.
  boot.loader.grub.enable = true;

  # 2 GiB of swap, for evaluating this flake at a switch.
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 2048;
    }
  ];
}
