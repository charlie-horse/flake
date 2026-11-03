{ lib, config, ... }: let
    inherit (lib)
        mkIf;
    inherit (config.custom.user)
        mkOutOfStoreSymlink;
    inherit (config.age)
        secrets;
in mkIf config.custom.age.enable {
    security.pam = {
        u2f = {
            enable = true;
            settings.cue = true;
            settings.origin = "pam://sortofasian";
        };
        services.login.u2fAuth = true;
        services.sudo.u2fAuth = true;
    };
    custom.user.configFile."Yubico/u2f_keys"
        .source = mkOutOfStoreSymlink secrets.pam-yubikeys.path;
}
