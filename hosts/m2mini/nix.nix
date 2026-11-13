{ lib, config, ... }:
let
  inherit (lib)
    mkForce
    ;
  user = config.users.users.charlie;
in
{
  environment.variables.NIXPKGS_ALLOW_UNFREE = "1";

  nixpkgs.hostPlatform = "aarch64-linux";
  nixpkgs.config.allowUnfree = true;

  nix = {
    gc.automatic = true;
    settings =
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
  };

  # r440's binary cache, https://cache.neuros.is (modules/system/nix-cache.nix).
  # r440 builds and holds x86_64 only (no aarch64 binary in its store,
  # 2026-11-12), so m2mini gets only arch-independent paths from it
  # (sources, fixed-output downloads, data). netrc: sops key
  # nix-cache-netrc in secrets/m2mini.yaml (formerly /var/lib/nix-cache/
  # netrc, made by hand; docs/cluster.md, "Binary cache"); without it Nix
  # warns and uses cache.nixos.org alone.
  custom.nixCache.enable = true;
}
