{ pkgs, ... }:
{
  config.fonts = {
    fontDir.enable = true;
    packages =
      with pkgs;
      # `nerd-fonts.<font>` where nixpkgs has it, else the `nerdfonts`
      # bundle. Same fonts and family names either way.
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
