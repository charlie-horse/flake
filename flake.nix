{
    inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
        np-master.url = "github:NixOS/nixpkgs/master";
        np-stable.url = "github:NixOS/nixpkgs/nixos-24.05";

        darwin.url = "github:lnl7/nix-darwin";
        darwin.inputs.nixpkgs.follows = "nixpkgs";

        home-manager.url = "github:nix-community/home-manager";
        home-manager.inputs.nixpkgs.follows = "nixpkgs";

        generators.url = "github:nix-community/nixos-generators";
        generators.inputs.nixpkgs.follows = "nixpkgs";

        agenix.url = "github:ryantm/agenix";
        agenix.inputs.nixpkgs.follows = "nixpkgs";

        apple-silicon.url = "github:tpwrules/nixos-apple-silicon";
        apple-silicon.inputs.nixpkgs.follows = "nixpkgs";

        aagl.url = "github:ezKEa/aagl-gtk-on-nix";
        aagl.inputs.nixpkgs.follows = "nixpkgs";

        madness.url = "github:antithesishq/madness";

        # ---- Servers (mkServer: c4130, r440, m2mini) -------------------------
        # Pinned to the revs the hosts' own flakes run today, so moving a host
        # onto this flake does not change its nixpkgs. Bump deliberately.

        # c4130 + r440: nixos-26.05 branch.
        nixpkgs-2605.url =
            "github:NixOS/nixpkgs/c3eea5b2156db11c7eeeada3dc737711255b253e";
        # c4130's `unstable` specialArg (nixpkgs-unstable branch).
        nixpkgs-unstable-c4130.url =
            "github:NixOS/nixpkgs/c7def046b9a883d46974757852106483d741586f";
        # m2mini: nixos-26.05 branch at m2mini's lock rev.
        nixpkgs-m2mini.url =
            "github:NixOS/nixpkgs/6d663c0533ff269008fb84e45930151e37c99db9";

        # c4130 vLLM (packages + nixosModules.vllm/lmcache).
        vllm-fork.url =
            "github:charlie-horse/vLLM/b7b1753dc8565af4327d9d21c1ed5cf444c0ddc3";
        vllm-fork.inputs.nixpkgs.follows = "nixpkgs-2605";

        # m2mini's Asahi support (the `apple-silicon` input above is
        # Miniserver's: tpwrules fork on unstable; don't repoint it).
        apple-silicon-m2mini.url =
            "github:nix-community/nixos-apple-silicon/57a14ae9be0eaf7bf66e95490ed2d7c6f4bd4c9e";
        apple-silicon-m2mini.inputs.nixpkgs.follows = "nixpkgs-m2mini";

        # TODO(Gus/m2mini): placeholder dir without firmware.cpio (proprietary,
        # never committed). Deploy on m2mini with
        #   --override-input m2mini-vendorfw path:/boot/vendorfw
        # See hosts/m2mini/firmware.nix. Drop this input if Gus stops using it.
        m2mini-vendorfw.url = "path:./hosts/m2mini/vendorfw";
        m2mini-vendorfw.flake = false;

        # Kubernetes manifests in Nix (k8s/ renders every in-cluster resource).
        catenix.url = "github:charlie-horse/catenix";
        # One nixpkgs for the renders (helm, kubeconform): the nodes' 26.05.
        catenix.inputs.nixpkgs.follows = "nixpkgs-2605";
    };

    outputs = { nixpkgs, ... }@inputs: let
        # In-cluster manifests (catenix); x86_64-linux only.
        k8s = import ./k8s {
            inherit inputs;
            pkgs = inputs.nixpkgs-2605.legacyPackages.x86_64-linux;
            lib = inputs.nixpkgs-2605.lib;
        };
        # Operator-side PKI tool (docs/pki.md).
        clusterPki = system:
            inputs.nixpkgs-2605.legacyPackages.${system}.callPackage
                ./pkgs/cluster-pki {
                    definition = import ./cluster/definition.nix;
                };
    in rec {
        lib = (nixpkgs.lib.extend (final: _: {
            custom = import ./lib { inherit inputs; lib = final; };
        })).custom;

        nixosConfigurations = lib.merge [
            (lib.system.x86_64-linux.mkHost ./hosts/Famine)
            (lib.system.x86_64-linux.mkHost ./hosts/Pestilence)
            (lib.system.x86_64-linux.mkHost ./hosts/Death)
            (lib.system.aarch64-linux.mkHost ./hosts/Miniserver)

            # Servers: only the host dir + modules/cluster (no desktop,
            # home-manager or agenix). See lib/system/mkServer.nix.
            (lib.system.x86_64-linux.mkServer {
                path = ./hosts/c4130;
                nixpkgs = inputs.nixpkgs-2605;
                specialArgs.unstable = import inputs.nixpkgs-unstable-c4130 {
                    system = "x86_64-linux";
                    config.allowUnfree = true;
                };
            })
            (lib.system.x86_64-linux.mkServer {
                path = ./hosts/r440;
                nixpkgs = inputs.nixpkgs-2605;
            })
            (lib.system.aarch64-linux.mkServer {
                path = ./hosts/m2mini;
                nixpkgs = inputs.nixpkgs-m2mini;
                # Same order as m2mini's own flake: apple-silicon first.
                preModules = [ inputs.apple-silicon-m2mini.nixosModules.default ];
                modules = [
                    { m2mini.vendorFirmware = inputs.m2mini-vendorfw; }
                ];
            })
        ];

        darwinConfigurations = lib.merge [
            (lib.system.aarch64-darwin.mkHost ./hosts/War)
        ];

       packages = lib.merge [
           (lib.system.x86_64-linux.mkHostIso "Famine")
           (lib.system.x86_64-linux.mkHostIso "Pestilence")
           (lib.system.x86_64-linux.mkHostIso "Death")
           {
               # catenix render of ./k8s: one YAML file per component, what
               # k8s/rendered/ holds and Flux applies (see k8s/README.md).
               x86_64-linux.k8s-manifests = k8s.packages.k8s-manifests;
           }
           (nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: {
               cluster-pki = clusterPki system;
           }))
       ];

        # nix run .#cluster-pki             -> ./pki-out (CAs + leaves)
        # nix run .#cluster-pki-deploy -- <node>  (stage + print sudo cmds)
        # nix run .#k8s-render [-- --check] -> k8s/rendered/
        apps = let
            pkiApps = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ]
                (system: let pki = clusterPki system; in {
                    cluster-pki = {
                        type = "app";
                        program = "${pki}/bin/cluster-pki";
                    };
                    cluster-pki-deploy = {
                        type = "app";
                        program = "${pki}/bin/cluster-pki-deploy";
                    };
                });
        in pkiApps // {
            x86_64-linux = pkiApps.x86_64-linux // {
                k8s-render = k8s.apps.render;
                k8s-check-images = k8s.apps.check-images;
            };
        };
    };
}
