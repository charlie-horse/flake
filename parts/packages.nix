# Per-system packages and apps.
#
# Everything here uses inputs.nixpkgs-2605 (the nodes' 26.05), not
# flake-parts' perSystem `pkgs` (which would be nixpkgs unstable).
{ inputs, config, ... }: {
    perSystem = { system, ... }: let
        pkgs2605 = inputs.nixpkgs-2605.legacyPackages.${system};
        # Operator-side PKI tool (docs/pki.md).
        pki = pkgs2605.callPackage ../pkgs/cluster-pki {
            definition = import ../cluster/definition.nix;
        };
        # In-cluster manifests (catenix); x86_64-linux only.
        k8s = import ../k8s {
            inherit inputs;
            pkgs = pkgs2605;
            lib = inputs.nixpkgs-2605.lib;
        };
        x86 = system == "x86_64-linux";
        optional = cond: set: if cond then set else {};
    in {
        packages = {
            cluster-pki = pki;
        } // optional x86 ({
            # catenix render of ./k8s: one YAML file per component, what
            # k8s/rendered/ holds and Flux applies (see k8s/README.md).
            k8s-manifests = k8s.packages.k8s-manifests;
        }
        # Installer ISOs for the desktop hosts (lib/system/mkHost.nix).
        // (config.flake.lib.system.${system}.mkHostIso "Famine").${system}
        // (config.flake.lib.system.${system}.mkHostIso "Pestilence").${system});

        # nix run .#cluster-pki             -> ./pki-out (CAs + leaves)
        # nix run .#cluster-pki-deploy -- <node>  (stage + print sudo cmds)
        # nix run .#k8s-render [-- --check] -> k8s/rendered/
        apps = {
            cluster-pki = {
                type = "app";
                program = "${pki}/bin/cluster-pki";
            };
            cluster-pki-deploy = {
                type = "app";
                program = "${pki}/bin/cluster-pki-deploy";
            };
        } // optional x86 {
            k8s-render = k8s.apps.render;
            k8s-check-images = k8s.apps.check-images;
        };
    };
}
