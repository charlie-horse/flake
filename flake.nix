{
    inputs = {
        # Two nixpkgs, pinned by flake.lock (`nix flake update <name>` to move
        # one deliberately):
        #   nixpkgs           nixos-26.05: the servers (c4130, r440, m2mini),
        #                     the per-system packages/apps and the flake-parts
        #                     skeleton.
        #   nixpkgs-unstable  nixos-unstable: ONLY the desktops (Famine,
        #                     Pestilence), their ISOs and the flake-level `lib`
        #                     that mkHost passes them. Every desktop-side
        #                     input follows it.
        nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
        nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

        # Only lib from it, for the module system that wires the outputs.
        flake-parts.url = "github:hercules-ci/flake-parts";
        flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

        # ---- Desktops (mkHost: Famine, Pestilence) -------------------------
        home-manager.url = "github:nix-community/home-manager";
        home-manager.inputs.nixpkgs.follows = "nixpkgs-unstable";

        generators.url = "github:nix-community/nixos-generators";
        generators.inputs.nixpkgs.follows = "nixpkgs-unstable";

        agenix.url = "github:ryantm/agenix";
        agenix.inputs.nixpkgs.follows = "nixpkgs-unstable";

        aagl.url = "github:ezKEa/aagl-gtk-on-nix";
        aagl.inputs.nixpkgs.follows = "nixpkgs-unstable";

        # ---- Servers (mkServer: c4130, r440, m2mini) -------------------------
        # All on `nixpkgs` (nixos-26.05).

        # c4130 vLLM (packages + nixosModules.vllm/lmcache). Tracks branch
        # `latest` of the fork; `nix flake update vllm-fork` to move it.
        vllm-fork.url = "github:charlie-horse/vLLM/latest";
        vllm-fork.inputs.nixpkgs.follows = "nixpkgs";

        # m2mini's Asahi support (pinned rev; bump deliberately).
        apple-silicon-m2mini.url =
            "github:nix-community/nixos-apple-silicon/57a14ae9be0eaf7bf66e95490ed2d7c6f4bd4c9e";
        apple-silicon-m2mini.inputs.nixpkgs.follows = "nixpkgs";

        # TODO(Gus/m2mini): placeholder dir without firmware.cpio (proprietary,
        # never committed). Deploy on m2mini with
        #   --override-input m2mini-vendorfw path:/boot/vendorfw
        # See hosts/m2mini/firmware.nix. Drop this input if Gus stops using it.
        m2mini-vendorfw.url = "path:./hosts/m2mini/vendorfw";
        m2mini-vendorfw.flake = false;

        # Kubernetes manifests in Nix (k8s/ renders every in-cluster resource).
        catenix.url = "github:charlie-horse/catenix";
        # One nixpkgs for the renders (helm, kubeconform): the nodes' 26.05.
        catenix.inputs.nixpkgs.follows = "nixpkgs";
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
