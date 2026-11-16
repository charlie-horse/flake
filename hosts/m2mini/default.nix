# m2mini: Apple Mac mini (M2, 2023), aarch64 Asahi, NixOS 26.05; etcd
# member, control plane and arm64 worker. Built with lib mkServer in
# parts/hosts.nix (never mkHost). Deploy with
#   --override-input m2mini-vendorfw path:/boot/vendorfw
# Host doc (wiring, inputs, deploy, history): docs/hosts/m2mini.md
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
