# m2mini: Apple Mac mini (M2, 2023; apple,j473 / t8112), aarch64 Asahi,
# NixOS 26.05. etcd member (name "m2mini", peer https://m2mini:2380) and,
# with the cluster module, a Kubernetes worker (arm64).
#
# Ported from m2mini's standalone flake (/etc/nixos: flake.nix, m2mini.nix,
# mod/{neovim,boot,nix,shell,xdg}). Not ported:
#   - mod/k8s.nix (etcd with certs as Nix paths, cri-o, ports 2379/2380 open
#     on every interface): the shared cluster module (modules/cluster +
#     cluster/definition.nix) replaces it. It stays out of tree; the parity
#     proof imports it from /etc/nixos.
#   - mod/tls/: private keys, never in git or the store.
#   - the plaintext user password (see ./configuration.nix).
#
# Must NOT go through lib mkHost (that imports every modules/** file:
# desktop, home-manager, agenix); it is built with lib mkServer
# (lib/system/mkServer.nix: host dir + modules/cluster + modules/server).
# Flake wiring, in parts/hosts.nix (no extra specialArgs needed):
#   lib.system.aarch64-linux.mkServer {
#     path = ../hosts/m2mini;
#     nixpkgs = inputs.nixpkgs-m2mini;
#     preModules = [ inputs.apple-silicon-m2mini.nixosModules.default ];
#     modules = [ { m2mini.vendorFirmware = inputs.m2mini-vendorfw; } ];
#   }
# The inputs it uses (flake.nix) are all kept, and are m2mini's own:
#   nixpkgs-m2mini        github:NixOS/nixpkgs @ 6d663c05 (nixos-26.05)
#   apple-silicon-m2mini  github:nix-community/nixos-apple-silicon @ 57a14ae9,
#                         nixpkgs follows nixpkgs-m2mini
#   m2mini-vendorfw       path:./hosts/m2mini/vendorfw, flake = false
#                         (placeholder, see ./firmware.nix)
# apple-silicon-m2mini is the flake's only Asahi input; keep it pinned to
# m2mini's lock rev (bump deliberately).
#
# Deploy on m2mini (firmware from the ESP, see ./firmware.nix):
#   nixos-rebuild switch --flake .#m2mini \
#     --override-input m2mini-vendorfw path:/boot/vendorfw
{ ... }:
{
  # Same order as the old flake's module list (k8s.nix sat after boot.nix).
  imports = [
    ./configuration.nix
    ./neovim
    ./boot.nix
    ./nix.nix
    ./shell.nix
    ./xdg.nix
    ./firmware.nix
  ];
}
