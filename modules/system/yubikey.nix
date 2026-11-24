# Per-user YubiKey files for the desktops (mkHost), from the host's sops
# file (sops.defaultSopsFile, secrets/<hostname>.yaml):
#
#   pam-yubikeys    pam_u2f mappings, linked to ~/.config/Yubico/u2f_keys:
#                   `<user>:<keyHandle>,<pubkey>,es256,+presence`, one line,
#                   from `pamu2fcfg -o pam://sortofasian -i pam://sortofasian`.
#
# The PAM side is custom.auth.desktopU2f (modules/system/auth), which this
# turns on. Off by default: the key must exist in the host's sops file
# first, or evaluation fails. docs/auth.md, "Desktop YubiKey".
{ lib, config, ... }:
let
  inherit (lib)
    mkIf
    mkEnableOption
    ;
  inherit (config.custom)
    user
    ;
  inherit (config.custom.user)
    mkOutOfStoreSymlink
    ;
  owned = {
    owner = user.name;
    mode = "0400";
  };
in
{
  options.custom.yubikey.enable = mkEnableOption ''
    the YubiKey sops secret pam-yubikeys (pam_u2f for login and sudo
    through custom.auth.desktopU2f)
  '';

  config = mkIf config.custom.yubikey.enable {
    sops.secrets = {
      pam-yubikeys = owned;
    };
    custom.auth.desktopU2f.enable = true;
    custom.user.configFile."Yubico/u2f_keys".source =
      mkOutOfStoreSymlink config.sops.secrets.pam-yubikeys.path;
  };
}
