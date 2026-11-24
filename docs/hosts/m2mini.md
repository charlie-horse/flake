# m2mini

m2mini is the Apple-silicon Mac mini cluster node, running NixOS through
Asahi (the Linux port to Apple silicon). Config: `hosts/m2mini/`.

## Deploy

As in [Changing a host](../cluster.md#changing-a-host), with the firmware
override:

```sh
cd /etc/nixos && git pull
sudo nixos-rebuild switch --flake /etc/nixos#m2mini \
  --override-input m2mini-vendorfw path:/boot/vendorfw
```

`--override-input` implies `--no-write-lock-file`. Without the override the
switch still works but drops the peripheral firmware (Wi-Fi, Bluetooth, …).

## Vendor firmware

Apple's peripheral firmware is proprietary and may not be redistributed.
On m2mini it is `/boot/vendorfw/firmware.cpio` on the EFI system partition.
Only `firmware.cpio` works; a raw `all_firmware.tar.gz` doesn't.

The flake input `m2mini-vendorfw` points by default at the firmware-free
placeholder `hosts/m2mini/vendorfw/`; the deploy override points it at
`/boot/vendorfw` (`hosts/m2mini/firmware.nix`).

Never copy `firmware.cpio`, `firmware.tar` or `manifest.txt` into
`hosts/m2mini/vendorfw/` or anywhere else in git.
