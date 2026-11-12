{ pkgs, ... }: {
  config.fonts = {
    fontDir.enable = true;
    packages = with pkgs; [
      (nerdfonts.override {
        fonts = [
          "FiraCode"
          "Noto"
        ];
      })
      corefonts
      noto-fonts
      noto-fonts-emoji
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
