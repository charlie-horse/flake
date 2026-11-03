{ lib, config, inputs, ... }: let
    inherit (lib)
        mkIf
        types
        mkOption;
    inherit (config.custom)
        genshin;
    inherit (inputs)
        aagl;
in {
    imports = [aagl.nixosModules.default];

    options.custom.genshin.enable = mkOption {
        type = types.bool;
        default = false;
    };

    config = mkIf genshin.enable {
        programs.anime-game-launcher.enable = true;
        nix.settings.substituters = ["https://ezkea.cachix.org"];
        nix.settings.trusted-public-keys = ["ezkea.cachix.org-1:ioBmUbJTZIKsHmWWXPe1FSFbeVe+afhfgqgTSNd34eI="];
    };
}
