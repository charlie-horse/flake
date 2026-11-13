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
{
  config,
  lib,
  inputs,
  ...
}:
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  sops = {
    # Through inputs.self, not a relative path: mkHost imports modules/
    # from its own store copy, which has no ../secrets.
    defaultSopsFile = "${inputs.self}/secrets/${lib.toLower config.networking.hostName}.yaml";
    age = {
      sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
      keyFile = null;
      generateKey = false;
    };
    gnupg.sshKeyPaths = [ ];
  };
}
