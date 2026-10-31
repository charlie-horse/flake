# m2mini vendor firmware placeholder

This directory is the default value of the `m2mini-vendorfw` flake input. It
deliberately contains no `firmware.cpio`: Apple's peripheral firmware is
proprietary and is not committed. With this placeholder the m2mini
configuration evaluates in CI with `hardware.asahi.extractPeripheralFirmware`
switched off (see `../firmware.nix`).

On m2mini, deploy with the real firmware from the ESP:

    nixos-rebuild switch --flake .#m2mini \
        --override-input m2mini-vendorfw path:/boot/vendorfw

Do not copy `firmware.cpio`, `firmware.tar` or `manifest.txt` here.
