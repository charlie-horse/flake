# The desktop user (custom.user.name). Desktops only
# (mkHost imports modules/ wholesale; mkServer does not). admin, root and
# users.mutableUsers: modules/system/admin.nix.
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
    # The desktop user's password (greeter, hyprlock; no sudo): the sops
    # key <user>-password in secrets/<hostname>.yaml. The host derives the
    # hash and sets hashedPasswordFile (custom.sopsPasswords,
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
