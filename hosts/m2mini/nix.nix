{ lib, config, ... }:
let
  inherit (lib)
    mkForce
    ;
  # The login accounts that may use (and are trusted by) the Nix daemon:
  # admin, and charlie while custom.server.legacyCharlie is on.
  logins = [
    "admin"
  ]
  ++ lib.optional config.custom.server.legacyCharlie.enable "charlie";
in
{
  environment.variables.NIXPKGS_ALLOW_UNFREE = "1";

  nixpkgs.hostPlatform = "aarch64-linux";
  nixpkgs.config.allowUnfree = true;

  nix = {
    gc.automatic = true;
    settings =
      let
        users = [ "root" ] ++ logins;
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
  };

  # The cluster's binary cache (modules/system/nix-cache.nix). It holds
  # x86_64 paths, so this host gets only arch-independent paths from it
  # (sources, fixed-output downloads, data). netrc: sops key
  # nix-cache-netrc in secrets/m2mini.yaml (docs/build-cache.md); without
  # it Nix warns and uses cache.nixos.org alone.
  custom.nixCache.enable = true;
}
