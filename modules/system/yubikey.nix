# Per-user YubiKey files for the desktops (mkHost), from the host's sops
# file (sops.defaultSopsFile, secrets/<hostname>.yaml). They replace the
# agenix secrets of the same names (modules/age), whose keys are lost.
#
#   pam-yubikeys    pam_u2f mappings (modules/system/pam.nix):
#                   `charlie:<keyHandle>,<pubkey>,es256,+presence`, one
#                   line. Make it at the machine with the YubiKey 5:
#                   `pamu2fcfg -o pam://sortofasian -i pam://sortofasian`.
#   ssh-yubikey-5   OpenSSH ed25519-sk "private key" file (key handle;
#                   useless without the YubiKey): IdentityFile for ssh
#                   (modules/programs/ssh.nix) and git signing key
#                   (modules/programs/git.nix). A resident key comes back with
#                   `ssh-keygen -K`; otherwise make a new one with
#                   `ssh-keygen -t ed25519-sk -O resident` and replace the
#                   public key wherever it is authorized (GitHub, hosts).
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
    the YubiKey sops secrets pam-yubikeys and ssh-yubikey-5 (pam_u2f for
    login and sudo, ssh identity, git signing key)
  '';

  config = mkIf config.custom.yubikey.enable {
    sops.secrets = {
      pam-yubikeys = owned;
      ssh-yubikey-5 = owned;
    };
  };
}
