{ pkgs, ... }:
{
  # prisma-language-server: top-level where nixpkgs has it, else from
  # pkgs.nodePackages.
  prisma-language-server = pkgs.prisma-language-server or pkgs.nodePackages."@prisma/language-server";
  inherit (pkgs) tailwindcss-language-server;
}
