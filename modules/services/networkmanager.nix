{
  pkgs,
  lib,
  config,
  ...
}:
let
  inherit (lib)
    mkIf
    types
    mkOption
    ;
  inherit (config.custom)
    user
    networkmanager
    ;
in
{
  options.custom.networkmanager.enable = mkOption {
    type = types.bool;
    default = true;
  };

  config = mkIf networkmanager.enable {
    networking.networkmanager.enable = true;
    users.users.${user.name}.packages = with pkgs; [
      networkmanagerapplet
    ];
  };
}
