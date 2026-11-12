# Flake-level outputs: the `lib` output and every nixosConfiguration.
#
# Hosts are built exactly as before flake-parts: lib.custom (./lib) is
# nixpkgs-unstable's lib extended with `custom`, and each host gets the plain
# flake `inputs` (not flake-parts' `inputs'`) and its own nixpkgs instance.
# Nothing from perSystem (`pkgs` etc.) reaches host evaluation.
#
# Which nixpkgs:
#   - desktops (mkHost): nixpkgs-unstable. mkHost calls this lib's
#     nixosSystem and passes the lib itself as specialArgs, so it must stay
#     nixpkgs-unstable's lib for the desktops to stay on unstable.
#   - servers (mkServer): `nixpkgs` (26.05), through `nixpkgs.lib.nixosSystem`
#     of the input passed in. They take only eval-time helpers (mkDefault,
#     removeSuffix) from this lib; no unstable package reaches them.
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
    # Pestilence is archived (hosts/Pestilence/README.md): its files stay,
    # but it is not an output, so it is neither built nor checked. To
    # restore it, re-add
    #   (lib.system.x86_64-linux.mkHost ../hosts/Pestilence)
    # here (and its ISO in parts/packages.nix) and fix it for the current
    # nixpkgs-unstable.

    # Servers: only the host dir + modules/cluster (no desktop,
    # home-manager or agenix). See lib/system/mkServer.nix.
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
      # Same order as m2mini's own flake: apple-silicon first.
      preModules = [ inputs.apple-silicon-m2mini.nixosModules.default ];
      modules = [
        { m2mini.vendorFirmware = inputs.m2mini-vendorfw; }
      ];
    })
  ];
}
