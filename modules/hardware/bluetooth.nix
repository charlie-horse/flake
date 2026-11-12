{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (builtins)
    elem
    ;
  inherit (lib)
    mkIf
    types
    mkOption
    ;
  inherit (config.custom)
    user
    bluetooth
    ;
in
{
  options.custom.bluetooth.enable = mkOption {
    type = types.bool;
    default = false;
  };

  config = mkIf bluetooth.enable {
    hardware.bluetooth.enable = true;
    hardware.bluetooth.package = pkgs.bluez;
    services.blueman.enable = true;
    users.users.${user.name}.packages = [ pkgs.rofi-bluetooth ];
  };
}
