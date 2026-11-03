{
    inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
        np-master.url = "github:NixOS/nixpkgs/master";
        np-stable.url = "github:NixOS/nixpkgs/nixos-24.05";

        flake-parts.url = "github:hercules-ci/flake-parts";
        flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

        home-manager.url = "github:nix-community/home-manager";
        home-manager.inputs.nixpkgs.follows = "nixpkgs";

        generators.url = "github:nix-community/nixos-generators";
        generators.inputs.nixpkgs.follows = "nixpkgs";

        agenix.url = "github:ryantm/agenix";
        agenix.inputs.nixpkgs.follows = "nixpkgs";

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

        # m2mini's Asahi support.
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

    # flake-parts: ./parts/hosts.nix holds `lib` and nixosConfigurations,
    # ./parts/packages.nix the per-system packages and apps.
    outputs = inputs@{ flake-parts, ... }:
        flake-parts.lib.mkFlake { inherit inputs; } {
            systems = [ "x86_64-linux" "aarch64-linux" ];
            imports = [
                ./parts/hosts.nix
                ./parts/packages.nix
            ];
        };
}
