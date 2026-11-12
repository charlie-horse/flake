{ pkgs, lib, ... }: {
  environment.systemPackages = [ pkgs.alacritty ];
  custom.user.configFile."alacritty/alacritty.yml".text = lib.generators.toYAML { } {
    env.TERM = "alacritty";
    key_bindings = [ ];

    window = {
      padding.x = 10;
      padding.y = 10;
      dynamic_padding = true;
      decorations = "none";
      opacity = 0.85;
      dynamic_title = true;
    };

    font.size = 13;
    font.normal = {
      family = "FiraCode Nerd Font";
      style = "Medium";
    };

    cursor.style.blinking = "Always";
    cursor.unfocused_hollow = false;

    colors = {
      primary.foreground = "0xa9b1d6";
      primary.background = "0x24283b";

      normal = {
        white = "0x9699a8";
        red = "0xf7768e";
        yellow = "0xe0af68";
        green = "0x9ece6a";
        cyan = "0x449dab";
        blue = "0x7aa2f7";
        magenta = "0xad8ee6";
        black = "0x32344a";
      };

      bright = {
        white = "0xacb0d0";
        red = "0xff7a93";
        yellow = "0xff9e64";
        green = "0xb9f27c";
        cyan = "0x0db9d7";
        blue = "0x7da6ff";
        magenta = "0xbb9af7";
        black = "0x444b6a";
      };
    };
  };
}
