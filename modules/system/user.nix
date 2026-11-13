# The desktop user (custom.user.name; Famine: charlie). Desktops only
# (mkHost imports modules/ wholesale; mkServer does not; the servers'
# charlie is modules/server/legacy-charlie.nix until stage 2 of the 2026-11
# charlie removal). admin, root and users.mutableUsers: modules/system/admin.nix.
{ lib, config, ... }:
let
  inherit (lib)
    types
    mkOption
    ;
  inherit (config.custom)
    user
    ;
in
{
  options.custom.user = {
    # TODO: need to add assertions
    name = mkOption {
      type = types.str;
      default = "";
    };
    home = mkOption {
      type = types.path;
      default = "/home/${user.name}";
    };
    uid = mkOption {
      type = types.int;
      default = 1000;
    };
  };

  config = {
    # The desktop user keeps a password (greeter, hyprlock; no sudo). The
    # plaintext is the sops key <user>-password (the option's default; on
    # Famine charlie-password) in sops.defaultSopsFile,
    # secrets/<hostname>.yaml (Famine: famine.yaml); the host derives the
    # yescrypt hash and sets hashedPasswordFile (custom.sopsPasswords,
    # modules/system/sops.nix).
    custom.sopsPasswords.${user.name} = { };

    users = {
      groups = {
        "plugdev" = { };
      };
      users.${user.name} = {
        uid = 1000;
        inherit (user) name home;
        group = "users";
        isNormalUser = true;
        # Not wheel: sudo is admin's (modules/system/admin.nix); likewise
        # not a nix trusted-user (modules/system/nix.nix).
        extraGroups = [
          "dialout"
          "plugdev"
        ];
      };
    };
  };
}
