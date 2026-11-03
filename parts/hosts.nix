# Flake-level outputs: the `lib` output and every nixosConfiguration.
#
# Hosts are built exactly as before flake-parts: lib.custom (./lib) is
# nixpkgs.lib extended with `custom`, and each host gets the plain flake
# `inputs` (not flake-parts' `inputs'`) and its own nixpkgs instance. Nothing
# from perSystem (`pkgs` etc.) reaches host evaluation.
{ inputs, config, ... }: let
    inherit (inputs) nixpkgs;
    lib = config.flake.lib;
in {
    flake.lib = (nixpkgs.lib.extend (final: _: {
        custom = import ../lib { inherit inputs; lib = final; };
    })).custom;

    flake.nixosConfigurations = lib.merge [
        (lib.system.x86_64-linux.mkHost ../hosts/Famine)
        (lib.system.x86_64-linux.mkHost ../hosts/Pestilence)

        # Servers: only the host dir + modules/cluster (no desktop,
        # home-manager or agenix). See lib/system/mkServer.nix.
        (lib.system.x86_64-linux.mkServer {
            path = ../hosts/c4130;
            nixpkgs = inputs.nixpkgs-2605;
        })
        (lib.system.x86_64-linux.mkServer {
            path = ../hosts/r440;
            nixpkgs = inputs.nixpkgs-2605;
        })
        (lib.system.aarch64-linux.mkServer {
            path = ../hosts/m2mini;
            nixpkgs = inputs.nixpkgs-m2mini;
            # Same order as m2mini's own flake: apple-silicon first.
            preModules = [ inputs.apple-silicon-m2mini.nixosModules.default ];
            modules = [
                { m2mini.vendorFirmware = inputs.m2mini-vendorfw; }
            ];
        })
    ];
}
