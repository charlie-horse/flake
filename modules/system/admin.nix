# Local accounts on every host: admin (the only wheel account, FIDO2 SSH
# login, password from sops via custom.sopsPasswords) and root, locked
# wherever users are immutable. Details and the lockout risk: docs/auth.md,
# "sops-nix on the hosts".
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
