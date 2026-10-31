{ pkgs, ... }: let
    inherit (pkgs.vimUtils)
        buildVimPlugin;
in {
    nvim-deadcolumn = buildVimPlugin {
        name = "nvim-deadcolumn";
        src = pkgs.fetchgit {
            url = "https://github.com/Bekaboo/deadcolumn.nvim";
            tag = "v1.0.2";
            hash = "sha256-/EtRvosijeVAMa7vQhcrFRkOs+gslDUHmbvbIGTjqr8=e";
        };
    };
}
