{ pkgs, ... }:
{
  # nixos-unstable removed pkgs.nodePackages. tailwindcss-language-server
  # is top-level in both nixpkgs; prisma-language-server only in the new
  # one, so fall back to nodePackages until flake.lock moves.
  prisma-language-server = pkgs.prisma-language-server or pkgs.nodePackages."@prisma/language-server";
  inherit (pkgs) tailwindcss-language-server;
}
