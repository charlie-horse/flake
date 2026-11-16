# charlie on the servers during the move to `admin`, in two stages so that
# no switch both creates admin and removes charlie:
#   stage 1 (enable = true, the default): charlie (as before PR #37) next to
#     admin; users.mutableUsers = true, so existing /etc/shadow lines
#     (charlie, root) are left alone.
#   stage 2 (false, set per host in hosts/<host>/configuration.nix; all three
#     servers today): mutableUsers = false, root locked, no charlie.
# /etc/nixos's owner follows the same switch (modules/server/default.nix).
# Why two stages, rollback behaviour, the procedure:
# docs/history/charlie-removal-2026-11.md
{ config, lib, ... }:
let
  cfg = config.custom.server.legacyCharlie;
in
{
  options.custom.server.legacyCharlie.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Keep the pre-sops `charlie` account (wheel, password from /etc/shadow)
      and mutable users on this server next to `admin`. Turn off only after
      admin is verified on every server and their pre-sops system
      generations are deleted (docs/history/charlie-removal-2026-11.md).
    '';
  };

  config = {
    # Overrides admin.nix's mkDefault false. Stage 1: leave existing
    # /etc/shadow entries (charlie, root) untouched.
    users.mutableUsers = cfg.enable;

    users.users.charlie = lib.mkIf cfg.enable {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      # No hashedPassword/hashedPasswordFile: with mutableUsers the existing
      # /etc/shadow hash stays. Host-specific bits: hosts/m2mini.
    };
  };
}
