# m2mini vendor firmware placeholder

The default value of the `m2mini-vendorfw` flake input. It holds no
`firmware.cpio` (Apple's firmware is proprietary), so firmware extraction
is off unless the deploy overrides the input. Never copy `firmware.cpio`,
`firmware.tar` or `manifest.txt` here.

Deploying m2mini with the firmware:
[docs/hosts/m2mini.md](../../../docs/hosts/m2mini.md#vendor-firmware).
