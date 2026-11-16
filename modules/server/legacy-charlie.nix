# enable = true: a `charlie` wheel account next to admin, mutable users.
# enable = false (set on every server): admin only, immutable users, root locked.
# /etc/nixos's owner follows it (modules/server/default.nix).
{ config, lib, ... }:
let
  cfg = config.custom.server.legacyCharlie;
in
{
  options.custom.server.legacyCharlie.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Keep a `charlie` account (wheel, password from /etc/shadow) and
      mutable users on this server next to `admin`.
    '';
  };

  config = {
    # Overrides admin.nix's mkDefault false. On: existing /etc/shadow
    # entries (charlie, root) stay untouched.
    users.mutableUsers = cfg.enable;

    users.users.charlie = lib.mkIf cfg.enable {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      # No hashedPassword/hashedPasswordFile: with mutableUsers the existing
      # /etc/shadow hash stays. Host-specific bits: hosts/m2mini.
    };
  };
}
