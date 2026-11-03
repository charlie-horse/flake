{ pkgs, lib, config, ... }: let
    inherit (lib)
        mkIf
        types
        mkOption;
    inherit (config.custom)
        user
        audio;
in {
    options.custom.audio.enable = mkOption {
        type = types.bool;
        default = true;
    };

    config = mkIf audio.enable {
        security.rtkit.enable = true;
        services.pipewire = {
            enable = true;
            wireplumber.enable = true;
            pulse.enable = true;
            jack.enable = true;
            alsa.enable = true;
        };
        users.users.${user.name}.packages = with pkgs; [
            pavucontrol
            pulseaudio
        ];
    };
}
