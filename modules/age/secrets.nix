{ lib, name, config, ... }: let
    inherit (lib)
        mkIf
        mkMerge;
    inherit (lib.custom)
        switch;
    inherit (config.custom)
        age
        user;
in mkIf age.enable {
    age.secrets = mkMerge [
        {
            login.file = ./secrets/login.age;
            pam-yubikeys.file   = ./secrets/pam-yubikeys.age;
            ssh-yubikey-5.file  = ./secrets/ssh-yubikey-5.age;
            ssh-yubikey-5c.file = ./secrets/ssh-yubikey-5c.age;

            pam-yubikeys.owner   = user.name;
            ssh-yubikey-5.owner  = user.name;
            ssh-yubikey-5c.owner = user.name;
        }
        (mkIf (name == "Pestilence") {
            vpn-privkey.file     = ./secrets/vpn-privkey.age;
            vpn-password.file    = ./secrets/vpn-password.age;
            acme-cloudflare.file = ./secrets/acme-cloudflare.age;
        })
    ];

    custom.age.systemIdentity.file = switch name (c: v: c==v) {
        "Famine"     = ./secrets/key-famine.age;
        "Pestilence" = ./secrets/key-pestilence.age;
    };
}
