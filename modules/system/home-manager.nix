{ lib, config, inputs, ... }: let
    inherit (lib)
        mkIf
        types
        mkOption;
    inherit (inputs.home-manager)
        nixosModules;
    inherit (config.custom)
        user;
in {
    imports = [ nixosModules.home-manager ];

    options.custom.user = {
        file = mkOption {
            type = types.attrs;
            default = {};
        };
        configFile = mkOption {
            type = types.attrs;
            default = {};
        };
        dataFile = mkOption {
            type = types.attrs;
            default = {};
        };
        mkOutOfStoreSymlink = mkOption {
            type = types.functionTo types.path;
            default = config.home-manager.users.${user.name}.lib.file.mkOutOfStoreSymlink;
        };
    };

    config = mkIf (user.name != "") {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;

        home-manager.users.${user.name} = {
            home.file = user.file;
            home.stateVersion = "22.11";
            xdg.configFile = user.configFile;
            xdg.dataFile = user.dataFile;
        };
    };
}
