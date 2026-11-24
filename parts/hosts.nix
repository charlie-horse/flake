# Flake-level outputs: the `lib` output and every nixosConfiguration.
#
# lib.custom (./lib) is nixpkgs-unstable's lib extended with `custom`. Each
# host gets the plain flake `inputs` (not flake-parts' `inputs'`) and its
# own nixpkgs instance; nothing from perSystem (`pkgs` etc.) reaches host
# evaluation.
#
# Which nixpkgs:
#   - desktops (mkHost): nixpkgs-unstable. mkHost uses this lib's
#     nixosSystem, so this lib must stay nixpkgs-unstable's.
#   - servers (mkServer): `nixpkgs`, through the nixosSystem of the input
#     passed in. They take only eval-time helpers from this lib.
{ inputs, config, ... }:
let
  lib = config.flake.lib;
in
{
  flake.lib =
    (inputs.nixpkgs-unstable.lib.extend (
      final: _: {
        custom = import ../lib {
          inherit inputs;
          lib = final;
        };
      }
    )).custom;

  flake.nixosConfigurations = lib.merge [
    (lib.system.x86_64-linux.mkHost ../hosts/Famine)
    # hosts/Pestilence is not an output (neither built nor checked).

    # Servers: only the host dir + modules/cluster + modules/server (no
    # desktop or home-manager; sops-nix and the admin account come through
    # modules/server). See lib/system/mkServer.nix.
    (lib.system.x86_64-linux.mkServer {
      path = ../hosts/c4130;
      nixpkgs = inputs.nixpkgs;
    })
    (lib.system.x86_64-linux.mkServer {
      path = ../hosts/r440;
      nixpkgs = inputs.nixpkgs;
    })
    (lib.system.aarch64-linux.mkServer {
      path = ../hosts/m2mini;
      nixpkgs = inputs.nixpkgs;
      # apple-silicon is imported before the host dir.
      preModules = [ inputs.apple-silicon-m2mini.nixosModules.default ];
      modules = [
        { m2mini.vendorFirmware = inputs.m2mini-vendorfw; }
      ];
    })
  ];
}
