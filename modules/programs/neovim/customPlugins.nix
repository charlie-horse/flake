{ pkgs, ... }:
let
  inherit (pkgs.vimUtils)
    buildVimPlugin
    ;
in
{
  nvim-deadcolumn = buildVimPlugin {
    name = "nvim-deadcolumn";
    src = pkgs.fetchFromGitHub {
      owner = "Bekaboo";
      repo = "deadcolumn.nvim";
      rev = "8140fd7cface9592a44b3151203fc6ca95ad9598";
      sha256 = "sha256-a/6hxK1ttxBEcXvOAEdCgDSLRydAEUEngyrOeK3yFJg=";
    };
  };
  #   nvim-transparent = buildVimPlugin {
  #       name = "nvim-transparent";
  #       src = pkgs.fetchFromGitHub {
  #           owner = "xiyaowong";
  #           repo = "nvim-transparent";
  #           rev = "2d8d650fc8a3b8da6a01031295547295eb473b7d";
  #           sha256 = "sha256-j1PO0r2q5w0fJvO7BG0xXDjIdOVl73eGO1rclB221uw=";
  #       };
  #   };
}
