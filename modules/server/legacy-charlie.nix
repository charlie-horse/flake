# charlie on the servers during the move to `admin` (docs/cluster.md,
# "Removing charlie from the servers (2026-11)"). Two stages, so `main` is
# deployable with a plain `git pull && nixos-rebuild switch` at every step
# and no switch both creates admin and removes charlie:
#
#   stage 1, custom.server.legacyCharlie.enable = true (the default):
#     admin is created next to charlie. users.mutableUsers = true, as
#     before the sops switch, so /etc/shadow entries of EXISTING accounts
#     are left alone (nixpkgs 26.05 update-users-groups.pl only rewrites an
#     existing shadow line when mutableUsers is false): charlie keeps the
#     password set with `passwd`, root keeps whatever it had. charlie is
#     declared exactly as on main before PR #37 (wheel; m2mini: uid 1000,
#     dialout, fish, Nix trust), with no password option. A brand-new admin
#     gets its hash from hashedPasswordFile at creation (the perl script's
#     "new account" branch); afterwards, while mutable, a changed
#     admin-password does NOT reach /etc/shadow (see modules/system/admin.nix).
#     Rolling back or booting a pre-sops generation only removes admin
#     (listed in /var/lib/nixos/declarative-users) and leaves charlie as he
#     was.
#
#   stage 2, false (a one-line follow-up PR once admin works on every host
#     and the pre-sops generations are deleted): users.mutableUsers = false,
#     root locked ("!", modules/system/admin.nix), no charlie on the servers.
#
# /etc/nixos's owner follows the same switch (modules/server/default.nix).
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
      generations are deleted (docs/cluster.md, "Removing charlie from the
      servers").
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
