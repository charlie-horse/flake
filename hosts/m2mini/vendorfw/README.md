# m2mini vendor firmware placeholder

Default value of the `m2mini-vendorfw` flake input. It deliberately contains
no `firmware.cpio`: Apple's peripheral firmware is proprietary and never
committed, so CI evaluates m2mini with firmware extraction off.

On m2mini, deploy with `--override-input m2mini-vendorfw path:/boot/vendorfw`.
Do not copy `firmware.cpio`, `firmware.tar` or `manifest.txt` here.

Details: [docs/hosts/m2mini.md](../../../docs/hosts/m2mini.md#vendor-firmware).
