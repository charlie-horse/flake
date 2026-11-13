# Local accounts on every host (desktops via modules/, servers via
# modules/server/default.nix): one central admin account, root locked,
# users fully declarative.
#
#   admin  the only account in wheel. Logs in with a FIDO2 resident key
#          (sk-ssh-ed25519, on the YubiKey) over SSH; sudo asks for its
#          password. Its one source of truth is the PLAINTEXT sops key
#          `admin-password` in secrets/common.yaml (read it with
#          `sops -d --extract '["admin-password"]' secrets/common.yaml`).
#          The host decrypts it to /run/secrets-for-users/admin-password
#          (neededForUsers: ramfs, root 0400) and derives the yescrypt
#          hash from it at activation into
#          /run/secrets-for-users/admin-password-hash, admin's
#          hashedPasswordFile (custom.sopsPasswords, modules/system/sops.nix).
#          To change it, edit `admin-password` and switch every host.
#          (The old `admin-password-hash` key may still sit in common.yaml;
#          it is unused and nothing may declare it.)
#   root   locked (no password, no keys); become root with `sudo -i` as
#          admin.
#   charlie exists only on desktops (modules/system/user.nix); the
#          servers have no other login account.
#
# users.mutableUsers = false: /etc/passwd, /etc/shadow and /etc/group are
# rebuilt from this config at every activation. Passwords set with
# `passwd` and accounts made with `useradd` do not survive a switch.
#
# LOCKOUT WARNING: if the host cannot decrypt secrets/common.yaml (its
# ssh-to-age recipient missing from .sops.yaml, or the file not re-encrypted
# with `sops updatekeys` after adding it), admin has no password and sudo
# fails for everyone. Both causes are checked automatically (details in
# modules/system/sops.nix): CI's secrets-guard compares every sops file's
# recipients with .sops.yaml, and on the host the pre-switch check
# `sopsDecrypt` decrypts every sops file the new generation uses with the
# host key and refuses the switch if any fails. If decryption still fails
# at activation, the previous admin hash in /etc/shadow is kept.
{ config, inputs, ... }:
let
  # FIDO2 resident keys allowed to log in as admin (one per line).
  adminAuthorizedKeys = [
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIMOzLvxaCcRrhYX3MODuBBDsZQTIvhOV4vLLQt+WHn/3AAAACXNzaDphZG1pbg== admin@yubikey-19830800"
  ];
in
{
  # sops.secrets.admin-password (neededForUsers) and its derived hash.
  # Through inputs.self: mkHost's store copy of modules/ has no ../secrets.
  custom.sopsPasswords.admin.sopsFile = "${inputs.self}/secrets/common.yaml";

  users = {
    mutableUsers = false;

    users.admin = {
      isNormalUser = true;
      description = "Local administrator";
      extraGroups = [ "wheel" ];
      # hashedPasswordFile: custom.sopsPasswords.admin (above).
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
