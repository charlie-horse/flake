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
  config.custom.theme.colors = mkIf (theme.colorscheme == "darkviolet") {
    main = "4136d9";
    fg = "b08ae6";
    bg = "000000";
    black = "000000";
    brightblack = "593380";
    red = "a82ee6";
    brightred = "bb66cc";
    green = "4595e6";
    brightgreen = "231a40";
    yellow = "f29df2";
    brightyellow = "432d59";
    blue = "4136d9";
    brightblue = "00ff00";
    magenta = "7e5ce6";
    brightmagenta = "9045e6";
    cyan = "40dfff";
    brightcyan = "a886bf";
    white = "b08ae6";
    brightwhite = "a366ff";
  };
}
