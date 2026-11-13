# Per-user YubiKey files for the desktops (mkHost), from the host's sops
# file (sops.defaultSopsFile, secrets/<hostname>.yaml). They replace the
# agenix secrets of the same names (modules/age), whose keys are lost.
#
#   pam-yubikeys    pam_u2f mappings (modules/system/pam.nix):
#                   `charlie:<keyHandle>,<pubkey>,es256,+presence:...`, one
#                   line, both YubiKeys. Make it at the machine with both
#                   keys: `pamu2fcfg -o pam://sortofasian -i pam://sortofasian`
#                   then `pamu2fcfg -n -o pam://sortofasian -i pam://sortofasian`
#                   for the second key, appended to the same line.
#   ssh-yubikey-5   OpenSSH ed25519-sk "private key" files (key handles;
#   ssh-yubikey-5c  useless without the YubiKey): IdentityFile for ssh
#                   (modules/programs/ssh.nix) and git signing keys
#                   (modules/programs/git.nix). Resident keys come back with
#                   `ssh-keygen -K`; otherwise make new ones with
#                   `ssh-keygen -t ed25519-sk -O resident` and replace the
#                   public keys wherever they are authorized (GitHub, hosts).
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
  owned = {
    owner = user.name;
    mode = "0400";
  };
in
{
  options.custom.yubikey.enable = mkEnableOption ''
    the YubiKey sops secrets pam-yubikeys, ssh-yubikey-5 and ssh-yubikey-5c
    (pam_u2f for login and sudo, ssh identities, git signing aliases)
  '';

  config = mkIf config.custom.yubikey.enable {
    sops.secrets = {
      pam-yubikeys = owned;
      ssh-yubikey-5 = owned;
      ssh-yubikey-5c = owned;
    };
  };
}
