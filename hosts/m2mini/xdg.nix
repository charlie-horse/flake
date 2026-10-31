{ lib, config, ... }: let
    inherit (builtins)
        toString;
    inherit (lib)
        types
        mkOption;
    inherit (config.custom) xdg;
    user = config.users.users.charlie;

    mkPath = default: mkOption { type = types.path; inherit default; };
in {
    options.custom.xdg = {
        cache   = mkPath "${user.home}/.cache";
        config  = mkPath "${user.home}/.config";
        local   = mkPath "${user.home}/.local";
        data    = mkPath "${xdg.local}/share";
        state   = mkPath "${xdg.local}/state";
        bin     = mkPath "${xdg.local}/bin";
        runtime = mkPath "/run/user/${toString user.uid}";
    };

    config.environment.variables = {
        XDG_CACHE_HOME  = xdg.cache;
        XDG_CONFIG_HOME = xdg.config;
        XDG_DATA_HOME   = xdg.data;
        XDG_STATE_HOME  = xdg.state;
        XDG_BIN_HOME    = xdg.bin;
        XDG_RUNTIME_DIR = xdg.runtime;

        HISTFILE        = "${xdg.data}/bash/history";
        INPUTRC         = "${xdg.config}/readline/inputrc";
        LESSHISTFILE    = "${xdg.state}/lesshst";
        WGETRC          = "${xdg.config}/wgetrc";
    };
}
