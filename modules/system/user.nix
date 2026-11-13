# The desktop user (custom.user.name; Famine: charlie). Desktops only
# (mkHost imports modules/ wholesale); the servers' charlie is
# modules/server/users.nix. admin (the only wheel member), root and
# users.mutableUsers = false: modules/system/admin.nix.
{ lib, config, ... }:
let
  inherit (lib)
    types
    mkOption
    mkIf
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
    # ======================================================================
    # CHOICE (open question, 2026-11): does the desktop user keep a password?
    #
    # On the servers charlie has none (modules/server/users.nix). A desktop
    # user without a password cannot log in at the graphical greeter or
    # unlock hyprlock, so for now Famine's charlie KEEPS one: its hash is the
    # sops key `charlie-password-hash` in secrets/famine.yaml
    # (`mkpasswd -m yescrypt`; the agenix `login` secret is lost). It no
    # longer gives sudo: charlie is not in wheel, sudo is admin's.
    #
    # Set this to false to lock charlie's password like on the servers
    # (then only an SSH key or another login method gets in).
    # ======================================================================
    keepPassword = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Give the desktop user a password from the sops key
        `charlie-password-hash` in the host's sops file (neededForUsers).
        When false the password is locked ("*").
      '';
    };
  };

  config = {
    sops.secrets.charlie-password-hash = mkIf user.keepPassword {
      # sops.defaultSopsFile: secrets/<hostname>.yaml (Famine: famine.yaml).
      neededForUsers = true;
    };

    users = {
      groups = {
        "plugdev" = { };
      };
      users.${user.name} = {
        uid = 1000;
        inherit (user) name home;
        group = "users";
        isNormalUser = true;
        # Not wheel: sudo is admin's (modules/system/admin.nix).
        extraGroups = [
          "dialout"
          "plugdev"
        ];
      }
      // (
        if user.keepPassword then
          { hashedPasswordFile = config.sops.secrets.charlie-password-hash.path; }
        else
          { hashedPassword = "*"; }
      );
    };
  };
}
