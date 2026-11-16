# Apple peripheral firmware (Wi-Fi, Bluetooth, webcam, ...): proprietary,
# never committed. The flake input m2mini-vendorfw is a firmware-free
# placeholder; on m2mini deploy with
#   --override-input m2mini-vendorfw path:/boot/vendorfw
# Without it (CI) extraction is off and the config still builds.
# docs/hosts/m2mini.md#vendor-firmware
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  dir = config.m2mini.vendorFirmware;
  hasFirmware = dir != null && builtins.pathExists "${dir}/firmware.cpio";
in
{
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
