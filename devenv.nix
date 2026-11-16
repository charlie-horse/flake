{ pkgs, ... }:

{
  # Secrets (sops-nix; recipients in .sops.yaml, files in secrets/):
  #   sops secrets/<file>.yaml       edit (needs an admin identity)
  #   sops updatekeys <file>         re-encrypt after a .sops.yaml change
  #   ssh-to-age < host_key.pub      a host's age recipient
  #   age-plugin-yubikey, ykman      the admin YubiKey (PIV age identity)
  packages = with pkgs; [
    sops
    age
    age-plugin-yubikey
    ssh-to-age
    yubikey-manager
  ];

  # Pre-commit: sops files are fully encrypted, to their .sops.yaml recipients.
  git-hooks.hooks.sops-files = {
    enable = true;
    name = "sops files";
    entry = "${pkgs.python3.withPackages (p: [ p.pyyaml ])}/bin/python3 -I scripts/check-sops.py";
    files = "^(\\.sops\\.yaml|secrets/.*|k8s/secrets/.*)$";
    pass_filenames = false;
  };

  enterShell = ''
    git pull
  '';
}
