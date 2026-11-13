{ config, inputs, ... }:
let
  # modules/ is desktop-only (mkHost), so the desktops' nixpkgs.
  nixpkgs = inputs.nixpkgs-unstable;
  inherit (config.custom)
    user
    ;
in
{
  nixpkgs.config.allowUnfree = true;
  nix.gc.automatic = true;
  nix.nixPath = [ "nixpkgs=${nixpkgs}" ];
  environment.variables.NIXPKGS_ALLOW_UNFREE = "1";
  nix.settings = {
    experimental-features = [
      "flakes"
      "nix-command"
    ];
    auto-optimise-store = true;
    # trusted-users is root-equivalent (it can import unsigned store paths
    # and set any nix option), so it follows wheel: root and admin only.
    # The desktop user is not in wheel (modules/system/user.nix) and may
    # only use the daemon.
    trusted-users = [
      "root"
      "admin"
    ];
    allowed-users = [
      "root"
      "admin"
      user.name
    ];
  };
  system.stateVersion = "23.05";
}
