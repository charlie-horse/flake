{ pkgs, ... }: {
  prisma-language-server = pkgs.nodePackages."@prisma/language-server";
  tailwindcss-language-server = pkgs.nodePackages."@tailwindcss/language-server";
  omnisharp-roslyn = pkgs.callPackage ./omnisharp-roslyn { };
  inherit (pkgs.callPackage ./cssmodules-lsp { }) cssmodules-language-server;
}
