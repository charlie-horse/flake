{ lib, pkgs, config, ... }: let
    inherit (config.custom)
        theme;
    inherit (builtins)
        toString;
in {
    environment.systemPackages = [ (pkgs.rofi.override {
        plugins = with pkgs; [ rofi-calc rofi-emoji ];
    }) ];
    custom.user.configFile."rofi/config.rasi".text = ''
        configuration {
            modes: [ drun, calc, emoji ];
            scroll-method: 0;
            drun-match-fields: [ name, generic, exec ];
            drun-display-format: "{name}";
        }

        * {
            accent:        #${theme.colors.main};
            foreground:    #${theme.colors.fg};
            background:    #${theme.colors.bg};
            red:           #${theme.colors.red};
            yellow:        #${theme.colors.yellow};
            green:         #${theme.colors.green};
            cyan:          #${theme.colors.cyan};
            blue:          #${theme.colors.blue};
            magenta:       #${theme.colors.magenta};
            white:         #${theme.colors.white};
            black:         #${theme.colors.black};
            brightred:     #${theme.colors.brightred};
            brightyellow:  #${theme.colors.brightyellow};
            brightgreen:   #${theme.colors.brightgreen};
            brightcyan:    #${theme.colors.brightcyan};
            brightblue:    #${theme.colors.brightblue};
            brightmagenta: #${theme.colors.brightmagenta};
            brightwhite:   #${theme.colors.brightwhite};
            brightblack:   #${theme.colors.brightblack};
        }

        window {
            transparency: "real";
            location: center;
            anchor: center;
            fullscreen: false;
            width: 800px;
            x-offset: 0px;
            y-offset: 0px;

            enabled: true;
            margin: 0px;
            padding: 0px;
            border: 0px solid;
            border-radius: ${toString theme.cornerRadius}px;
            border-color: @accent;
            background-color: @background;
            font: "Sans 12";

            //children: [ inputbar, listview, message ];
        }

        mainbox {
            enabled: true;
            spacing: 10px;
            margin: 0px;
            padding: ${toString theme.gapSize};
            border: 0px solid;
            border-radius: 0px 0px 0px 0px;
            border-color: @accent;
            background-color: transparent;

            children: [ "inputbar", "message", "listview" ];
        }

        inputbar {
            enabled: true;
            spacing: ${toString (theme.gapSize * 0.5)}px;
            margin: 0px;
            padding: 0px;
            border: 0px solid;
            border-radius: 0px;
            border-color: @accent;
            background-color: transparent;
            text-color: @accent;
            font: "Mono 12";

            children: [ "prompt", "textbox-prompt-colon", "entry" ];
        }

        prompt {
            enabled: true;
            background-color: inherit;
            text-color: inherit;
        }

        textbox-prompt-colon {
            enabled: true;
            expand: false;
            str: "❯";
            background-color: inherit;
            text-color: inherit;
        }

        entry {
            enabled: true;
            background-color: inherit;
            text-color: inherit;
            cursor: text;
            placeholder: "Search...";
            placeholder-color: inherit;
        }

        num-filtered-rows {
            enabled: true;
            expand: false;
            background-color: inherit;
            text-color: inherit;
        }

        textbox-num-sep {
            enabled: true;
            expand: false;
            str: "/";
            background-color: inherit;
            text-color: inherit;
        }

        num-rows {
            enabled: true;
            expand: false;
            background-color: inherit;
            text-color: inherit;
        }

        case-indicator {
            enabled: true;
            background-color: inherit;
            text-color: inherit;
        }

        listview {
            enabled: true;
            columns: 2;
            lines: 10;
            cycle: true;
            dynamic: true;
            scrollbar: false;
            layout: vertical;
            reverse: false;
            fixed-height: true;
            fixed-columns: true;

            spacing: ${toString (theme.gapSize * 0.25)}px;
            margin: 0px;
            padding: 0px;
            border: 0px solid;
            border-radius: 0px;
            border-color: @accent;
            background-color: transparent;
            text-color: @foreground;
            cursor: "default";
        }

        element {
            enabled: true;
            spacing: ${toString (theme.gapSize * 0.5)}px;
            margin: 0px;
            padding: ${let base = theme.gapSize * 0.25;
                in "${toString base}px ${toString (base * 2)}px" };
            border: 0px solid;
            border-radius: ${toString (theme.cornerRadius * 0.5)}px;
            border-color: @accent;
            background-color: transparent;
            text-color: @foreground;
            cursor: "pointer";
        }

        element normal.normal {
            background-color: @background;
            text-color: @foreground;
        }
        element normal.active {
            background-color: @background;
            text-color: @foreground;
        }

        element selected.normal {
            background-color: @foreground;
            text-color: @accent;
        }
        element selected.active {
            background-color: @foreground;
            text-color: @accent;
        }

        element alternate.normal {
            background-color: @background;
            text-color: @foreground;
        }
        element alternate.active {
            background-color: @background;
            text-color: @foreground;
        }

        element-icon {
            background-color: transparent;
            text-color: inherit;
            size: 24px;
            cursor: inherit;
        }

        element-text {
            background-color: transparent;
            text-color: inherit;
            highlight: inherit;
            cursor: inherit;
            vertical-align: 0.5;
            horizontal-align: 0.0;
        }

        message {
            enabled: true;
            margin: 0px;
            padding: 0px;
            border: 0px solid;
            border-radius: 0px 0px 0px 0px;
            border-color: @accent;
            background-color: transparent;
            text-color: @foreground;
        }

        textbox {
            padding: ${let base = theme.gapSize * 0.25;
                in "${toString base}px ${toString (base * 2)}px" };
            border: 1px solid;
            border-radius: ${toString (theme.cornerRadius * 0.5)}px;
            border-color: @accent;
            background-color: @background;
            text-color: @foreground;
            vertical-align: 0.5;
            horizontal-align: 0.0;
            highlight: none;
            placeholder-color: @foreground;
            blink: true;
            markup: true;
        }
        
        error-message {
            padding: ${toString (theme.gapSize * 0.5)}px;
            border: 2px solid;
            border-radius: ${toString (theme.cornerRadius)}px;
            border-color: @accent;
            background-color: @background;
            text-color: @foreground;
        }
    '';
}
