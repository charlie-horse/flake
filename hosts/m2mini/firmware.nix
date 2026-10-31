# Apple peripheral firmware (Wi-Fi, Bluetooth, webcam, ...).
#
# It is proprietary and non-redistributable, so it is NOT committed for this
# host. The Asahi installer put it on the ESP: /boot/vendorfw/firmware.cpio.
# (hosts/Miniserver/firmware is an older, raw `all_firmware.tar.gz` for an
# M2 machine; the current apple-silicon module needs `firmware.cpio`, so it
# cannot stand in for /boot/vendorfw.)
#
# How the flake feeds it (see the contract in ./default.nix):
#   inputs.m2mini-vendorfw = {
#       url = "path:./hosts/m2mini/vendorfw";  # placeholder dir, no firmware
#       flake = false;
#   };
#   modules = [ ... { m2mini.vendorFirmware = inputs.m2mini-vendorfw; } ];
# and deploy on m2mini with
#   nixos-rebuild switch --flake .#m2mini \
#       --override-input m2mini-vendorfw path:/boot/vendorfw
# (--override-input implies --no-write-lock-file). The override yields the
# same store path (`<nar-hash>-source`) as the old `vendorfw` input, so the
# toplevel is unchanged. Without the override (CI, other machines) the
# placeholder has no firmware.cpio and the extraction is switched off, so
# the configuration still evaluates and builds, just without the blobs.
{ lib, config, ... }:
let
    inherit (lib) mkOption types;
    dir = config.m2mini.vendorFirmware;
    hasFirmware = dir != null && builtins.pathExists "${dir}/firmware.cpio";
in {
    options.m2mini.vendorFirmware = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
            Directory holding the Asahi `firmware.cpio` (normally the
            /boot/vendorfw copy, passed as a flake input). null, or a
            directory without firmware.cpio, disables the extraction.
        '';
    };

    config.hardware.asahi = {
        # Always set: the module's default probes /boot/vendorfw, which is
        # forbidden in pure evaluation.
        peripheralFirmwareDirectory = if hasFirmware then dir else null;
        extractPeripheralFirmware = hasFirmware;
    };
}
