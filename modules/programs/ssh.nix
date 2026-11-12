{
  pkgs,
  lib,
  config,
  options,
  ...
}:
let
  inherit (config.age)
    secrets
    enable
    ;
in
{
  config = {
    programs.ssh.extraConfig = lib.mkIf config.custom.age.enable ''
      ForwardAgent yes
      IdentityFile = ${secrets.ssh-yubikey-5.path}
      IdentityFile = ${secrets.ssh-yubikey-5c.path}
    '';
    programs.ssh.startAgent = true;
    # nixos-unstable's gnome-keyring (Famine) also enables gcr-ssh-agent by
    # default, and only one SSH agent may run: keep OpenSSH's ssh-agent.
    # The option does not exist in older nixpkgs, hence the check.
    services.gnome = lib.optionalAttrs (options.services.gnome ? gcr-ssh-agent) {
      gcr-ssh-agent.enable = false;
    };
  };
}
