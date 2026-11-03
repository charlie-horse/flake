{ pkgs, lib, config, ... }: let
    inherit (config.age)
        secrets enable;
in {
    config = {
        programs.ssh.extraConfig = lib.mkIf config.custom.age.enable ''
            ForwardAgent yes
            IdentityFile = ${secrets.ssh-yubikey-5.path}
            IdentityFile = ${secrets.ssh-yubikey-5c.path}
        '';
        programs.ssh.startAgent = true;
    };
}
