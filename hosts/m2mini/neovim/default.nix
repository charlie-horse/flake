{ pkgs, lib, config, ... }: let
    inherit (pkgs.callPackage ./neovim.nix { inherit config; })
        neovim
        neovimBins;
in {
    environment.systemPackages = [(pkgs.symlinkJoin {
        name = "neovim";
        paths = [ neovim ];
        buildInputs = [ pkgs.makeWrapper ];
        postBuild = "wrapProgram $out/bin/nvim --suffix PATH : ${neovimBins}";
    })];

    environment.variables.EDITOR = lib.mkOverride 900 "nvim";
}
