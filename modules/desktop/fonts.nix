{ pkgs, ... }:
{
  config.fonts = {
    fontDir.enable = true;
    packages =
      with pkgs;
      # nixos-unstable split the `nerdfonts` bundle into `nerd-fonts.<font>`
      # and removed it. Same fonts and family names either way; keep only
      # the first branch once flake.lock's nixpkgs-unstable has nerd-fonts.
      (
        if pkgs ? nerd-fonts then
          [
            nerd-fonts.fira-code
            nerd-fonts.noto
          ]
        else
          [
            (nerdfonts.override {
              fonts = [
                "FiraCode"
                "Noto"
              ];
            })
          ]
      )
      ++ [
        corefonts
        noto-fonts
        noto-fonts-color-emoji
        noto-fonts-cjk-sans
        noto-fonts-cjk-serif
      ];
    enableDefaultPackages = false;
    fontconfig.defaultFonts = {
      emoji = [ "Noto Color Emoji" ];
      serif = [ "Noto Serif Nerd Font" ];
      sansSerif = [ "Noto Sans Nerd Font" ];
      monospace = [ "FiraCode Nerd Font Mono" ];
    };
  };
}
