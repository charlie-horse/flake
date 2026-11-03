{ lib, pkgs, config, ... }: let
    inherit (lib)
        mkIf
        types
        mkOption;
    inherit (lib.generators)
        toINI;
    inherit (config.custom)
        dunst
        theme;
in {
    options.custom.dunst = {
        enable = mkOption {
            type = types.bool; default = false;
        };
    };
    config = mkIf dunst.enable {
        environment.systemPackages = [ pkgs.dunst ];
        custom.user.configFile."dunst/dunstrc".text = toINI {} {
        };
    };
}
