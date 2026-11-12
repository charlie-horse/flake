{ lib, ... }:
let
  inherit (builtins)
    readDir
    ;
  inherit (lib)
    types
    mkOption
    removeSuffix
    mapAttrsToList
    ;
in
{
  options.custom.theme = {
    colorscheme = mkOption {
      type = types.enum (mapAttrsToList (name: _: removeSuffix ".nix" name) (readDir ./colorschemes));
      default = "tokyonight";
    };

    colors =
      let
        mkColor = mkOption { type = types.str; };
      in
      {
        main = mkColor;
        fg = mkColor;
        bg = mkColor;
        black = mkColor;
        brightblack = mkColor;
        red = mkColor;
        brightred = mkColor;
        green = mkColor;
        brightgreen = mkColor;
        yellow = mkColor;
        brightyellow = mkColor;
        blue = mkColor;
        brightblue = mkColor;
        magenta = mkColor;
        brightmagenta = mkColor;
        cyan = mkColor;
        brightcyan = mkColor;
        white = mkColor;
        brightwhite = mkColor;
      };

    opacity = mkOption {
      type = types.float;
      default = 0.9;
    };

    shadows = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };
      opacity = mkOption {
        type = types.float;
        default = 0.3;
      };
      radius = mkOption {
        type = types.int;
        default = 20;
      };
      offsetX = mkOption {
        type = types.int;
        default = -20;
      };
      offsetY = mkOption {
        type = types.int;
        default = -20;
      };
    };

    blur.enable = mkOption {
      type = types.bool;
      default = true;
    };
    blur.radius = mkOption {
      type = types.int;
      default = 20;
    };

    gapSize = mkOption {
      type = types.int;
      default = 10;
    };
    cornerRadius = mkOption {
      type = types.int;
      default = 10;
    };

    borderWidth = mkOption {
      type = types.int;
      default = 3;
    };

  };
}
