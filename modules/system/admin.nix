# Local accounts on every host (desktops via modules/, servers via
# modules/server/default.nix): one central admin account, root locked,
# users fully declarative.
#
#   admin  the only account in wheel. Logs in with a FIDO2 resident key
#          (sk-ssh-ed25519, on the YubiKey) over SSH; sudo asks for its
#          password, whose hash is the sops key `admin-password-hash` in
#          secrets/common.yaml (`mkpasswd -m yescrypt`). The plaintext is
#          kept next to it under `admin-password` for retrieval only: it is
#          deliberately NOT a sops.secrets entry, so it never reaches a host.
#   root   locked (no password, no keys); become root with `sudo -i` as
#          admin.
#   charlie (and other users) are declared elsewhere: servers in
#          modules/server/users.nix, desktops in modules/system/user.nix.
#
# users.mutableUsers = false: /etc/passwd, /etc/shadow and /etc/group are
# rebuilt from this config at every activation. Passwords set with
# `passwd` and accounts made with `useradd` do not survive a switch.
#
# LOCKOUT WARNING: if the host cannot decrypt secrets/common.yaml (its
# ssh-to-age recipient missing from .sops.yaml, or the file not re-encrypted
# with `sops updatekeys` after adding it), admin has no password and sudo
# fails for everyone. Check before switching:
#   sudo ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key \
#     | SOPS_AGE_KEY_FILE=/dev/stdin sops -d secrets/common.yaml >/dev/null
# (or simply that the host's anchor is a recipient of common.yaml).
{ config, inputs, ... }:
let
  # FIDO2 resident keys allowed to log in as admin (one per line).
  adminAuthorizedKeys = [
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIMOzLvxaCcRrhYX3MODuBBDsZQTIvhOV4vLLQt+WHn/3AAAACXNzaDphZG1pbg== admin@yubikey-19830800"
  ];
in
{
  sops.secrets."admin-password-hash" = {
    # Through inputs.self: mkHost's store copy of modules/ has no ../secrets.
    sopsFile = "${inputs.self}/secrets/common.yaml";
    # Decrypted to /run/secrets-for-users/ before users are created.
    neededForUsers = true;
  };

  users = {
    mutableUsers = false;

    users.admin = {
      isNormalUser = true;
      description = "Local administrator";
      extraGroups = [ "wheel" ];
      hashedPasswordFile = config.sops.secrets."admin-password-hash".path;
      openssh.authorizedKeys.keys = adminAuthorizedKeys;
    };

    users.root.hashedPassword = "!";
  };

  # sudo for wheel (= admin) always asks for admin's password.
  security.sudo.wheelNeedsPassword = true;
  assertions = [
    {
      assertion = config.security.sudo.wheelNeedsPassword;
      message = "modules/system/admin.nix: sudo must ask wheel (admin) for its password.";
    }
  ];
}
