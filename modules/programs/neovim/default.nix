{
  pkgs,
  lib,
  config,
  ...
}:
let
  inherit (pkgs.callPackage ./neovim.nix { inherit config; })
    neovim
    neovimBins
    ;
in
{
  options.custom.neovim = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    dev = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };
  config = lib.mkIf config.custom.neovim.enable {
    environment.systemPackages = [
      (pkgs.symlinkJoin {
        name = "neovim";
        paths = [ neovim ];
        buildInputs = [ pkgs.makeWrapper ];
        postBuild = "wrapProgram $out/bin/nvim --suffix PATH : ${neovimBins}";
      })
    ];

    environment.variables.EDITOR = lib.mkOverride 900 "nvim";
  };
}
