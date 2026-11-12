{
  pkgs,
  lib,
  config,
  ...
}:
let
  inherit (config.custom)
    theme
    ;
in
{
  environment.etc.hosts.mode = "0644";
  networking.firewall.enable = false;
  boot.extraModulePackages = with config.boot.kernelPackages; [ v4l2loopback ];
  boot.supportedFilesystems = [ "ntfs" ];
  boot.kernelParams = [ "nvidia_drm.fbdev=1" ];

  # Qt plugin paths for the installed profiles. The theme is set with
  # QT_QPA_PLATFORMTHEME below: NixOS dropped the "gtk2" platform theme and
  # style (qtstyleplugins; GTK 2 is end-of-life).
  qt.enable = true;

  services = {
    gnome.gnome-keyring.enable = true;
    tailscale.enable = true;
    udev.packages = [ pkgs.qmk-udev-rules ];
  };

  custom = {
    bluetooth.enable = true;
    cpu = "amd";
    gpu = "nvidia";
    cuda.enable = true;
    virtualisation.enable = true;

    user.name = "charlie";
    theme.colorscheme = "shadotheme";

    neovim.enable = true;
    neovim.dev = true;
    # alacritty.enable = false;
    # kitty.enable = true;
    # rofi.enable = true;
    direnv.enable = true;
    networkmanager.enable = true;
    audio.enable = true;
    udisks.enable = true;

    gaming.enable = true;
    steam = true;
    star-citizen.enable = true;

    # r440's binary cache, https://cache.neuros.is (modules/system/
    # nix-cache.nix), after cache.nixos.org. The netrc is the agenix secret
    # nix-cache-netrc (modules/age/secrets.nix); until that is committed,
    # the default path does not exist and Nix uses cache.nixos.org alone.
    nixCache = {
      enable = true;
      netrcFile = lib.mkIf (config.age.secrets ? nix-cache-netrc) config.age.secrets.nix-cache-netrc.path;
    };
  };

  programs.dconf.enable = true;
  environment.systemPackages = with pkgs; [
    gcc
    clang
    protontricks
    nautilus
    orchis-theme
    capitaine-cursors
    lxappearance

    prusa-slicer
    gparted
    ledger-live-desktop
    protonup-qt
    # Renamed to proton-vpn (protonvpn-gui is a deprecated alias).
    (pkgs.proton-vpn or protonvpn-gui)
    parsec-bin
    obs-studio
    imv
    mpv
    gimp
    #kicad
    # cider: removed from nixos-unstable (unmaintained, archived upstream).
    # Its successor is packaged as cider-2 (unfree, a paid app upstream);
    # add it here if wanted.
    lutris
    sioyek
    spotify
    libreoffice
    google-chrome
    firefox
    blender
    #obsidian
    eww
    prismlauncher
    #yuzu-early-access
    #(discord.override { withVencord = true; })
    discord
    rustup
  ];
  environment.variables = with config.custom; {
    "RUSTUP_HOME" = "${xdg.data}/rustup";
    "CARGO_HOME" = "${xdg.data}/cargo";
    "NPM_CONFIG_USERCONFIG" = "${xdg.config}/npm/npmrc";
    "GTK2_RC_FILES" = "${xdg.config}/gtk-2.0/gtkrc";
    # Qt follows the GTK theme (Orchis, picked with lxappearance) through
    # Qt's own GTK 3 platform theme (libqgtk3, built into qtbase for Qt 5
    # and 6): GTK palette, fonts, icons and file dialogs. Replaces
    # qt.platformTheme/qt.style "gtk2", which NixOS removed; its qt module
    # has no "gtk3" value, so set it directly.
    "QT_QPA_PLATFORMTHEME" = "gtk3";
  };
  environment.sessionVariables = {
    WLR_NO_HARDWARE_CURSORS = "1";
  };
  custom.user.configFile."npm/npmrc".text = with config.custom; ''
    prefix=${xdg.data}/npm
    cache=${xdg.cache}/npm
    init-module=${xdg.config}/npm/config/npm-init.js
  '';

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
  };

  xdg.sounds.enable = true;
  xdg.portal.enable = true;
  security.polkit.enable = true;
  systemd = {
    user.services.polkit-gnome-authentication-agent-1 = {
      description = "polkit-gnome-authentication-agent-1";
      wantedBy = [ "graphical-session.target" ];
      wants = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
        Restart = "on-failure";
        RestartSec = 1;
        TimeoutStopSec = 10;
      };
    };
  };

  home-manager.users.charlie = { pkgs, ... }: {
    wayland.windowManager.hyprland = {
      enable = true;
      systemd.enable = true;
      xwayland.enable = true;
      settings = {
        general = {
          gaps_in = 5;
          gaps_out = 20;
          border_size = 2;
          "col.active_border" = "rgba(33ccffee) rgba(00ff99ee) 45deg";
          "col.inactive_border" = "rgba(595959aa)";
          layout = "dwindle";
        };

        dwindle = {
          pseudotile = true;
          preserve_split = true;
        };

        decoration = {
          rounding = 10;
          blur.size = 3;
          blur.passes = 1;
          drop_shadow = false;
        };

        animations = {
          enabled = true;
          bezier = "myBezier, 0.05, 0.9, 0.1, 1.05";
          animation = [
            "windows, 1, 7, myBezier"
            "windowsOut, 1, 7, default, popin 80%"
            "border, 1, 10, default"
            "borderangle, 1, 8, default"
            "fade, 1, 7, default"
            "workspaces, 1, 6, default"
          ];
        };

        monitor = ",2560x1440@144,0x0,1";

        env = "XCURSOR_SIZE,24";
        exec-once = [
          "hypridle"
          "hyprpaper"
        ];

        input = {
          kb_layout = "us";
          touchpad.natural_scroll = false;
          sensitivity = 0;
          accel_profile = "flat";
          follow_mouse = 1;
        };

        misc.vrr = 1;
        misc.focus_on_activate = true;

        bind = with pkgs; [
          ", XF86AudioRaiseVolume, execr, ${pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ +5%"
          ", XF86AudioLowerVolume, execr, ${pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ -5%"
          ", XF86AudioPlay, execr, ${playerctl}/bin/playerctl play-pause"
          ", XF86AudioNext, execr, ${playerctl}/bin/playerctl next"
          ", XF86AudioPrev, execr, ${playerctl}/bin/playerctl previous"
          "SHIFT, XF86AudioPlay, execr, ${playerctl}/bin/playerctl shuffle toggle"

          "SUPER, d, execr, ${dunst}/bin/dunstctl close"
          "SUPER SHIFT, d, execr, dunstctl history-pop"

          "SUPER, return, execr, kitty"
          "SUPER, SPACE, execr, rofi -show drun"
          "SUPER, q, killactive,"
          "SUPER SHIFT, q, exit,"
          "SUPER SHIFT, l, execr, hyprlock"

          "SUPER, f, fullscreen"
          "SUPER, v, togglefloating"
          "SUPER, comma, togglesplit"

          "SUPER, h, movefocus, l"
          "SUPER, j, movefocus, d"
          "SUPER, k, movefocus, u"
          "SUPER, l, movefocus, r"

          "SUPER, y, movefocus, l"
          "SUPER, u, movefocus, d"
          "SUPER, i, movefocus, u"
          "SUPER, o, movefocus, r"

          "SUPER, 1, workspace, 01"
          "SUPER, 2, workspace, 02"
          "SUPER, 3, workspace, 03"
          "SUPER, 4, workspace, 04"
          "SUPER, 5, workspace, 05"
          "SUPER, 6, workspace, 06"
          "SUPER, 7, workspace, 07"
          "SUPER, 8, workspace, 08"
          "SUPER, 9, workspace, 09"
          "SUPER, 0, workspace, 10"

          "SUPER SHIFT, h, workspace, e-1"
          "SUPER SHIFT, l, workspace, e+1"

          "SUPER SHIFT, 1, movetoworkspace, 01"
          "SUPER SHIFT, 2, movetoworkspace, 02"
          "SUPER SHIFT, 3, movetoworkspace, 03"
          "SUPER SHIFT, 4, movetoworkspace, 04"
          "SUPER SHIFT, 5, movetoworkspace, 05"
          "SUPER SHIFT, 6, movetoworkspace, 06"
          "SUPER SHIFT, 7, movetoworkspace, 07"
          "SUPER SHIFT, 8, movetoworkspace, 08"
          "SUPER SHIFT, 9, movetoworkspace, 09"
          "SUPER SHIFT, -, movetoworkspace, 09"
          "SUPER SHIFT, 0, movetoworkspace, 10"
          "SUPER SHIFT, =, movetoworkspace, 10"
        ];

        workspace = [
          "01,default:true"
          "02"
          "03"
          "04"
          "05"
          "06"
          "07"
          "08"
          "09"
          "10"
        ];

        bindm = [
          "SUPER, mouse:272, movewindow"
          "SUPER, mouse:273, resizewindow"
        ];
      };
    };
    services = {
      hypridle = {
        enable = true;
        settings = {
          general = {
            lock_cmd = "pidof hyprlock || hyprlock";
          };
          listener = [
            {
              timeout = 5 * 60;
              on-timeout = "loginctl lock-session";
            }
            {
              timeout = 10 * 60;
              on-timeout = "hyprctl dispatch dpms off";
              on-resume = "hyprctl dispatch dpms on";
            }
          ];
        };
      };
      hyprpaper = {
        enable = true;
        settings = {
          preload = "/home/charlie/Images/Wallpapers/sky.png";
          wallpaper = "/home/charlie/Images/Wallpapers/sky.png";
          splash = true;
        };
      };
      dunst = {
        enable = true;
        settings = {
          global = {
            follow = "keyboard";
            notification_limit = 3;
            idle_threshold = 0;
            show_age_threshold = 15;
            sticky_history = true;
            history_length = 200;
            fullscreen = "pushback";

            origin = "bottom-center";
            offset = "0x85";
            gap_size = theme.gapSize;
            padding = theme.gapSize;
            horizontal_padding = theme.gapSize;
            width = 500;
            height = 200;
            frame_width = theme.borderWidth;
            corner_radius = theme.cornerRadius;

            transparency = 0;
            font = "Sans 12";

            show_indicators = false;
            alignment = "center";
            vertical_alignment = "center";
            word_wrap = true;
            markup = "full";
            format = ''"<b>%s</b>\n<span font='8'>%b</span>"'';

            enable_recursive_icon_lookup = true;
            icon_position = "left";
            min_icon_size = 64;
            max_icon_size = 64;
          };
          urgency_low = {
            background = ''"#${theme.colors.bg}"'';
            foreground = ''"#${theme.colors.fg}"'';
            highlight = ''"#${theme.colors.blue}"'';
            frame_color = ''"#${theme.colors.fg}"'';
            timeout = 5;
          };
          urgency_normal = {
            background = ''"#${theme.colors.bg}"'';
            foreground = ''"#${theme.colors.fg}"'';
            highlight = ''"#${theme.colors.blue}"'';
            frame_color = ''"#${theme.colors.fg}"'';
            timeout = 10;
          };
          urgency_critical = {
            background = ''"#${theme.colors.bg}ff"'';
            foreground = ''"#${theme.colors.fg}"'';
            highlight = ''"#${theme.colors.blue}"'';
            frame_color = ''"#${theme.colors.brightred}"'';
            timeout = 0;
          };
        };
      };
    };
    programs = {
      hyprlock = {
        enable = true;
        settings = {
          background = {
            monitor = "";
            path = "/home/charlie/Images/Wallpapers/sky.png";
            blur_passes = 3;
            blur_size = 7;
          };

          input-field = {
            monitor = "";
            hide_input = false;
            rounding = 5;

            size = "200, 50";
            position = "0, -20";
            halign = "center";
            valign = "center";
          };
        };
      };
    };
  };
}
