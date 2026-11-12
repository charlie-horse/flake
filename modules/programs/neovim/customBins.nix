{ pkgs, ... }: {
  prisma-language-server = pkgs.nodePackages."@prisma/language-server";
  tailwindcss-language-server = pkgs.nodePackages."@tailwindcss/language-server";
}
