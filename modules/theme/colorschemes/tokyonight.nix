{ lib, config, ... }:
let
  inherit (lib)
    mkIf
    ;
  inherit (config.custom)
    theme
    ;
in
{
  config.custom.theme.colors = mkIf (theme.colorscheme == "tokyonight") {
    main = "fecadd";
    fg = "a9b1d6";
    bg = "24283b";
    black = "32344a";
    brightblack = "444b6a";
    red = "f7768e";
    brightred = "ff7a93";
    green = "9ece6a";
    brightgreen = "b9f27c";
    yellow = "e0af68";
    brightyellow = "ff9e64";
    blue = "7aa2f7";
    brightblue = "7da6ff";
    magenta = "ad8ee6";
    brightmagenta = "bb9af7";
    cyan = "449dab";
    brightcyan = "0db9d7";
    white = "9699a8";
    brightwhite = "acb0d0";
  };
}
