# m2mini

The Asahi Mac mini cluster node (`hosts/m2mini/`).

## Deploy

As in [cluster.md, Changing a host](../cluster.md#changing-a-host), plus the
firmware override:

```sh
cd /etc/nixos && git pull
sudo nixos-rebuild switch --flake /etc/nixos#m2mini \
  --override-input m2mini-vendorfw path:/boot/vendorfw
```

`--override-input` implies `--no-write-lock-file`. Without the override the
switch still works but drops the peripheral firmware (Wi-Fi, Bluetooth, …).

## Vendor firmware

Apple's peripheral firmware (Wi-Fi, Bluetooth, webcam, …) is proprietary and
non-redistributable, so it is never committed. The Asahi installer put it on
the ESP as `/boot/vendorfw/firmware.cpio`. The current apple-silicon module
needs `firmware.cpio`; an older raw `all_firmware.tar.gz` cannot stand in.

The flake input `m2mini-vendorfw` defaults to the firmware-free placeholder
`hosts/m2mini/vendorfw/`; the deploy override above points it at
`/boot/vendorfw` (`hosts/m2mini/firmware.nix`).

Never copy `firmware.cpio`, `firmware.tar` or `manifest.txt` into
`hosts/m2mini/vendorfw/`.
