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
  nix.settings =
    let
      users = [
        "root"
        user.name
      ];
    in
    {
      experimental-features = [
        "flakes"
        "nix-command"
      ];
      auto-optimise-store = true;
      trusted-users = users;
      allowed-users = users;
    };
  system.stateVersion = "23.05";
}
