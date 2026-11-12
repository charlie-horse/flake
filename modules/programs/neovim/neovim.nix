{
  pkgs,
  lib,
  config,
  ...
}:
let
  neovimCfg = config.custom.neovim;
in
{
  neovim =
    with lib;
    (pkgs.neovim.override {
      configure.customRC =
        concatMapStrings
          # Read config file contents; supports lua files
          (
            f:
            if hasSuffix ".lua" f then
              "lua << EOF\n ${builtins.readFile f} \nEOF\n"
            else if hasSuffix ".vim" f then
              builtins.readFile f
            else
              ""
          )
          # get all files in the config dir
          (
            (filesystem.listFilesRecursive ./config/general)
            ++ (if neovimCfg.dev then filesystem.listFilesRecursive ./config/dev else [ ])
          );

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
        ])
        ++ (
          if neovimCfg.dev then
            [
              luasnip
              cmp-path
              cmp-emoji
              cmp_luasnip
              cmp-nvim-lsp
              lspkind-nvim
              nvim-lspconfig
              # rust-tools-nvim was removed from nixpkgs (abandoned). The
              # config never loaded it: rust_analyzer is set up through
              # lspconfig (config/dev/lsp.lua).
            ]
          else
            [ ]
        );
    });

  neovimBins = lib.strings.makeBinPath (
    (with pkgs; [
      fd
      ripgrep
    ])
    ++ (
      if neovimCfg.dev then
        (with pkgs; [
          nil
          taplo
          pyright
          clang-tools
          rust-analyzer
          jdt-language-server
          lua-language-server
          #java-language-server
        ])
        # Formerly pkgs.nodePackages.*, which nixos-unstable removed; these
        # are top-level packages in both the old and the new nixpkgs.
        ++ (with pkgs; [
          vim-language-server
          bash-language-server
          yaml-language-server
          svelte-language-server
          typescript-language-server
          vscode-langservers-extracted
          # Renamed from dockerfile-language-server-nodejs.
          (pkgs.dockerfile-language-server or dockerfile-language-server-nodejs)
        ])
        ++ (with (pkgs.callPackage ./customBins.nix { }); [
          prisma-language-server
          tailwindcss-language-server
        ])
      else
        [ ]
    )
    ++ [ pkgs.xclip ]
  );
}
