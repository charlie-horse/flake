# sops-nix on every host: the desktops get it with the rest of modules/
# (lib/system/mkHost.nix), the servers through modules/server/default.nix.
#
# Encrypted files (recipients: /.sops.yaml at the repo root):
#   secrets/<hostname>.yaml  this host only, e.g. secrets/c4130.yaml,
#                            secrets/famine.yaml (lowercase hostname); the
#                            default for every sops.secrets.<name>
#   secrets/common.yaml      every host; select it per secret with
#                            sopsFile = "${inputs.self}/secrets/common.yaml"
#
# Decryption key: the host's own SSH ed25519 host key, converted to an age
# identity at activation (its age recipient is `ssh-to-age` of the public
# key, which is what .sops.yaml lists). No GnuPG and no RSA host keys: both
# lists below are set explicitly so sops-nix's defaults (every RSA/ed25519
# key in services.openssh.hostKeys) never add one.
#
# Edit a file with `sops secrets/<file>.yaml` from the dev shell (devenv.nix:
# sops, age, age-plugin-yubikey, ssh-to-age). Secrets land in /run/secrets/
# (neededForUsers: /run/secrets-for-users/, before users are created).
#
# The host key must exist before the first activation decrypts anything. On
# the servers sshd made it long ago; Famine runs no sshd at all
# (services.openssh.enable = false), so the activation script below makes
# it when it is missing, without enabling or exposing sshd. It runs before
# sops-nix's setupSecretsForUsers (every host has one: admin's password
# hash), which runs before `users` and so before setupSecrets. An existing
# key is never touched; sshd, where enabled, uses the same file.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  hostKey = "/etc/ssh/ssh_host_ed25519_key";
in
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  system.activationScripts = {
    sopsHostKey = lib.stringAfter [ "specialfs" ] ''
      if [ ! -s ${hostKey} ]; then
        echo "generating ${hostKey} (sops-nix decryption identity)..."
        mkdir -p -m 0755 ${dirOf hostKey}
        ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "" -f ${hostKey}
      fi
    '';
    setupSecretsForUsers.deps = [ "sopsHostKey" ];
  };

  sops = {
    # Through inputs.self, not a relative path: mkHost imports modules/
    # from its own store copy, which has no ../secrets.
    defaultSopsFile = "${inputs.self}/secrets/${lib.toLower config.networking.hostName}.yaml";
    age = {
      sshKeyPaths = [ hostKey ];
      keyFile = null;
      generateKey = false;
    };
    gnupg.sshKeyPaths = [ ];
  };
}
