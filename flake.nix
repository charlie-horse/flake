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

        # c4130 vLLM (packages + nixosModules.vllm/lmcache). After cutover:
        # charlie-horse/vllm-sm70 (upstream vLLM + sm_70 patch series), a
        # drop-in for the old fork (github:charlie-horse/vLLM), same options.
        # No nixpkgs.follows: vllm-sm70 builds with its own pinned nixpkgs, so a
        # host nixpkgs bump (update.yml) cannot change the gated build.
        # The input keeps the name `vllm-fork` so hosts/c4130 is unchanged.
        # Pinned to cef0f9e (C1 passed, build aczb9zwk) until `latest` is
        # fast-forwarded to a gated commit; then point this at .../latest again.
        # (`latest` moves only after main
        # CI, the c4130 check, the GPU gate and release sign-off, same commit.)
        # `nix flake update vllm-fork` to move it.
        vllm-fork.url = "github:charlie-horse/vllm-sm70/latest";

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
