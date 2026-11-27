{
  inputs = {
    # Two nixpkgs, pinned by flake.lock (`nix flake update <name>` moves one):
    #   nixpkgs           the servers, the per-system packages and apps.
    #   nixpkgs-unstable  only the desktops, their ISOs and the flake-level
    #                     `lib`. Every desktop-side input follows it.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Only lib from it, for the module system that wires the outputs.
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    # ---- Desktops (mkHost) ----------------------------------------------
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs-unstable";

    generators.url = "github:nix-community/nixos-generators";
    generators.inputs.nixpkgs.follows = "nixpkgs-unstable";

    aagl.url = "github:ezKEa/aagl-gtk-on-nix";
    aagl.inputs.nixpkgs.follows = "nixpkgs-unstable";

    # ---- Secrets (every host) --------------------------------------------
    # sops-nix (modules/system/sops.nix) decrypts secrets/*.yaml on the hosts.
    # Must follow `nixpkgs`, not nixpkgs-unstable: modules/system/sops.nix
    # takes its sops tools from sops-nix's nixpkgs, on the desktops too.
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # ---- Servers (mkServer) ----------------------------------------------
    # All on `nixpkgs`.

    # vLLM for V100 GPUs (packages + nixosModules.vllm/lmcache).
    # Must not follow `nixpkgs`: vllm-sm70 builds with its own pinned nixpkgs.
    # Tracks the gated branch `latest`. docs/hosts/c4130-vllm.md.
    vllm-fork.url = "github:charlie-horse/vllm-sm70/latest";

    # m2mini's Asahi (Apple Silicon) support, pinned to a rev.
    apple-silicon-m2mini.url = "github:nix-community/nixos-apple-silicon/57a14ae9be0eaf7bf66e95490ed2d7c6f4bd4c9e";
    apple-silicon-m2mini.inputs.nixpkgs.follows = "nixpkgs";

    # Placeholder dir without firmware.cpio (proprietary, never committed).
    # Deploy on m2mini with
    #   --override-input m2mini-vendorfw path:/boot/vendorfw
    # docs/hosts/m2mini.md#vendor-firmware.
    m2mini-vendorfw.url = "path:./hosts/m2mini/vendorfw";
    m2mini-vendorfw.flake = false;

    # Declarative disk layout for hosts installed with nixos-anywhere
    # (modules/server/vps-disk.nix). docs/hosts/vps.md.
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # Kubernetes manifests in Nix (k8s/ renders every in-cluster resource).
    catenix.url = "github:charlie-horse/catenix";
    # The renders (helm, kubeconform) use the servers' nixpkgs.
    catenix.inputs.nixpkgs.follows = "nixpkgs";
  };

  # flake-parts: ./parts/hosts.nix holds `lib` and nixosConfigurations,
  # ./parts/packages.nix the per-system packages and apps, ./parts/k8s.nix
  # the system-independent k8s render (`k8s`).
  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      imports = [
        ./parts/hosts.nix
        ./parts/packages.nix
        ./parts/k8s.nix
        ./parts/checks.nix
      ];
    };
}
