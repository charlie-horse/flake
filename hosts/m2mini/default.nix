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
# desktop, home-manager, agenix). Flake wiring (no specialArgs needed):
#   inputs.nixpkgs-m2mini.url =
#     "github:NixOS/nixpkgs/6d663c0533ff269008fb84e45930151e37c99db9";
#   inputs.apple-silicon-m2mini.url =
#     "github:nix-community/nixos-apple-silicon/57a14ae9be0eaf7bf66e95490ed2d7c6f4bd4c9e";
#   inputs.apple-silicon-m2mini.inputs.nixpkgs.follows = "nixpkgs-m2mini";
#   inputs.m2mini-vendorfw = {
#     url = "path:./hosts/m2mini/vendorfw"; flake = false;
#   };
#   nixosConfigurations.m2mini = inputs.nixpkgs-m2mini.lib.nixosSystem {
#     modules = [
#       inputs.apple-silicon-m2mini.nixosModules.default
#       ./hosts/m2mini
#       { m2mini.vendorFirmware = inputs.m2mini-vendorfw; }
#       # + modules/cluster with the m2mini node from cluster/definition.nix
#     ];
#   };
# (The existing `apple-silicon` input is Miniserver's: tpwrules URL,
# follows unstable nixpkgs. Don't repoint it.)
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
