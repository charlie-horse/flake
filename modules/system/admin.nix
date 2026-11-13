# Local accounts on every host (desktops via modules/, servers via
# modules/server/default.nix): one central admin account, root locked,
# users fully declarative.
#
#   admin  the only account in wheel. Logs in with a FIDO2 resident key
#          (sk-ssh-ed25519, on the YubiKey) over SSH; sudo asks for its
#          password (or, with custom.auth.hardwareFactor, for the key
#          instead; modules/system/auth). The password's one source of
#          truth is the PLAINTEXT sops key
#          `admin-password` in secrets/common.yaml (read it with
#          `sops -d --extract '["admin-password"]' secrets/common.yaml`).
#          The host decrypts it to /run/secrets-for-users/admin-password
#          (neededForUsers: ramfs, root 0400) and derives the yescrypt
#          hash from it at activation into /run/sops-password-hashes/admin,
#          admin's hashedPasswordFile (custom.sopsPasswords,
#          modules/system/sops.nix).
#          To change it, edit `admin-password` and switch every host.
#   root   locked (no password, no keys) wherever users are immutable;
#          become root with `sudo -i` as admin.
#   charlie on desktops (modules/system/user.nix); on the servers only
#          while custom.server.legacyCharlie.enable is on
#          (modules/server/legacy-charlie.nix).
#
# users.mutableUsers = false (mkDefault: desktops, and servers once
# legacyCharlie is off): /etc/passwd, /etc/shadow and /etc/group are
# rebuilt from this config at every activation. Passwords set with
# `passwd` and accounts made with `useradd` do not survive a switch.
# Servers with legacyCharlie on are mutable (stage 1 of the move to admin):
# existing /etc/shadow entries are kept, root's "!" is not applied, and
# admin's hashedPasswordFile is used only when admin is CREATED; a later
# change of admin-password does not reach /etc/shadow there until
# legacyCharlie is off (or `passwd admin`).
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
{
  config,
  lib,
  inputs,
  ...
}:
let
  # FIDO2 resident keys allowed to log in as admin (one per line).
  adminAuthorizedKeys = [
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIMOzLvxaCcRrhYX3MODuBBDsZQTIvhOV4vLLQt+WHn/3AAAACXNzaDphZG1pbg== admin@yubikey-19830800"
  ];
in
{
  # sops.secrets.admin-password (neededForUsers) and its derived hash.
  # builtins.path: only this file goes to the store, not the flake source
  # (modules/system/sops.nix, header).
  custom.sopsPasswords.admin.sopsFile = builtins.path {
    path = "${inputs.self}/secrets/common.yaml";
    name = "common.yaml";
  };

  users = {
    mutableUsers = lib.mkDefault false;

    users.admin = {
      isNormalUser = true;
      description = "Local administrator";
      extraGroups = [ "wheel" ];
      # hashedPasswordFile: custom.sopsPasswords.admin (above).
      openssh.authorizedKeys.keys = adminAuthorizedKeys;
    };

    # Only applied to an existing root when users are immutable.
    users.root.hashedPassword = lib.mkIf (!config.users.mutableUsers) "!";
  };

  # sudo, polkit, console and sshd policy (admin's password, or the
  # hardware factor): modules/system/auth.
}
