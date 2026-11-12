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
  config.custom.theme.colors = mkIf (theme.colorscheme == "icy") {
    main = "00bcd4";
    fg = "095b67";
    bg = "021012";
    black = "021012";
    brightblack = "052e34";
    red = "16c1d9";
    brightred = "b3ebf2";
    green = "4dd0e1";
    brightgreen = "031619";
    yellow = "80deea";
    brightyellow = "041f23";
    blue = "00bcd4";
    brightblue = "064048";
    magenta = "00acc1";
    brightmagenta = "0c7c8c";
    cyan = "26c6da";
    brightcyan = "0097a7";
    white = "095b67";
    brightwhite = "109cb0";
  };
}
