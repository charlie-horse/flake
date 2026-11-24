{ pkgs, lib, ... }:
let
in
{
  neovim =
    with lib;
    (pkgs.neovim.override {
      configure.customRC =
        concatMapStrings
          # Read each config file: .lua wrapped in a lua heredoc, .vim as is
          (
            f:
            if hasSuffix ".lua" f then
              "lua << EOF\n ${builtins.readFile f} \nEOF\n"
            else if hasSuffix ".vim" f then
              builtins.readFile f
            else
              ""
          )
          # Every file in ./config
          (filesystem.listFilesRecursive ./config);

      configure.packages.neovimPlugins.start =
        with pkgs.vimPlugins;
        [
          nvim-cmp
          neoformat
          alpha-nvim
          plenary-nvim
          trouble-nvim
          nvim-autopairs
          telescope-nvim
          nvim-ts-autotag
          tokyonight-nvim
          nvim-web-devicons
          nvim-highlight-colors
          telescope-fzf-native-nvim
          gitsigns-nvim
          lualine-nvim
          telescope-file-browser-nvim
          nvim-treesitter.withAllGrammars
        ]
        ++ (with pkgs.callPackage ./customPlugins.nix { }; [
          nvim-deadcolumn
          #           nvim-transparent
        ]);
    });

  neovimBins = lib.strings.makeBinPath (
    with pkgs;
    [
      fd
      ripgrep
      git
    ]
  );
}
