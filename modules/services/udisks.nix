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
    udisks
    ;
in
{
  options.custom.udisks.enable = mkOption {
    type = types.bool;
    default = false;
  };

  config = mkIf udisks.enable {
    services.udisks2.enable = true;
    #users.users.${user.name}.packages = mkIf desktop.enable [ pkgs.udiskie ];
  };
}
