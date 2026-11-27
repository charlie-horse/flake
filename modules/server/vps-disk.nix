# Disk layout of the VPS hosts (nether, phoenix), for disko (the tool
# nixos-anywhere runs to partition and format the disk at install). Not in
# modules/server/default.nix: each VPS imports it from its
# hardware-configuration.nix. The VPS boot by BIOS, so GRUB goes into a
# 1 MiB BIOS boot partition; the rest is one ext4 root.
# Install procedure: docs/hosts/vps.md.
{ inputs, ... }:
{
  imports = [ inputs.disko.nixosModules.disko ];

  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/sda";
    content = {
      type = "gpt";
      partitions = {
        # disko adds this disk to boot.loader.grub.devices.
        bios = {
          size = "1M";
          type = "EF02";
          priority = 1;
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
