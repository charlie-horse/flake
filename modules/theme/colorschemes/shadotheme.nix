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
  config.custom.theme.colors = mkIf (theme.colorscheme == "shadotheme") {
    main = "ed749f";
    fg = "e3c7fc";
    bg = "191724";
    black = "a8899c";
    brightblack = "a8899c";
    red = "b52a5b";
    brightred = "b52a5b";
    green = "ff4971";
    brightgreen = "ff4971";
    yellow = "8897f4";
    brightyellow = "8897f4";
    blue = "bd93f9";
    brightblue = "bd93f9";
    magenta = "e9729d";
    brightmagenta = "e9729d";
    cyan = "f18fb0";
    brightcyan = "f18fb0";
    white = "f1c4e0";
    brightwhite = "f1c4e0";
  };
}
