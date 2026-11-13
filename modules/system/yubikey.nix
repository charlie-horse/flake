# Per-user YubiKey files for the desktops (mkHost), from the host's sops
# file (sops.defaultSopsFile, secrets/<hostname>.yaml). They replace the
# agenix secrets of the same names (modules/age), whose keys are lost.
#
#   pam-yubikeys    pam_u2f mappings, linked to ~/.config/Yubico/u2f_keys
#                   (pam_u2f's default authfile):
#                   `charlie:<keyHandle>,<pubkey>,es256,+presence`, one
#                   line. Make it at the machine with the YubiKey 5:
#                   `pamu2fcfg -o pam://sortofasian -i pam://sortofasian`.
#
# No separate ssh identity: ssh and git signing use the ssh:admin FIDO2
# key from the agent (modules/programs/ssh.nix, modules/programs/git.nix).
#
# The PAM side (pam_u2f as an alternative to the password) is
# custom.auth.desktopU2f in modules/system/auth, which this turns on.
#
# Off by default: every key must exist in the host's sops file first, or
# evaluation fails (sops-nix checks the file).
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
