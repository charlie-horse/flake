{
  lib,
  name,
  config,
  ...
}:
let
  inherit (lib)
    mkIf
    mkMerge
    ;
  inherit (lib.custom)
    switch
    ;
  inherit (config.custom)
    age
    user
    ;
in
mkIf age.enable {
  age.secrets = mkMerge [
    {
      login.file = ./secrets/login.age;
      pam-yubikeys.file = ./secrets/pam-yubikeys.age;
      ssh-yubikey-5.file = ./secrets/ssh-yubikey-5.age;
      ssh-yubikey-5c.file = ./secrets/ssh-yubikey-5c.age;

      pam-yubikeys.owner = user.name;
      ssh-yubikey-5.owner = user.name;
      ssh-yubikey-5c.owner = user.name;
    }
    (mkIf (name == "Pestilence") {
      vpn-privkey.file = ./secrets/vpn-privkey.age;
      vpn-password.file = ./secrets/vpn-password.age;
      acme-cloudflare.file = ./secrets/acme-cloudflare.age;
    })
    # netrc for r440's binary cache (custom.nixCache, hosts/Famine). Owned
    # by root, 0400: only the nix-daemon reads it. Declared once the
    # encrypted file is committed (docs/cluster.md, "Binary cache").
    (mkIf (name == "Famine" && builtins.pathExists ./secrets/nix-cache-netrc.age) {
      nix-cache-netrc.file = ./secrets/nix-cache-netrc.age;
    })
  ];

  custom.age.systemIdentity.file = switch name (c: v: c == v) {
    "Famine" = ./secrets/key-famine.age;
    "Pestilence" = ./secrets/key-pestilence.age;
  };
}
