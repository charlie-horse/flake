# pam_u2f (YubiKeys) for login and sudo; the mappings are the sops secret
# pam-yubikeys (modules/system/yubikey.nix). Off until that exists.
{ lib, config, ... }:
let
  inherit (lib)
    mkIf
    ;
  inherit (config.custom.user)
    mkOutOfStoreSymlink
    ;
  inherit (config.sops)
    secrets
    ;
in
mkIf config.custom.yubikey.enable {
  security.pam = {
    u2f = {
      enable = true;
      settings.cue = true;
      settings.origin = "pam://sortofasian";
    };
    services.login.u2fAuth = true;
    services.sudo.u2fAuth = true;
  };
  custom.user.configFile."Yubico/u2f_keys".source = mkOutOfStoreSymlink secrets.pam-yubikeys.path;
}
