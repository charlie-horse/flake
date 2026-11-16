# m2mini: Apple Mac mini (M2, 2023), aarch64 Asahi, NixOS 26.05; etcd
# member, control plane and arm64 worker. Built with lib mkServer in
# parts/hosts.nix (never mkHost). Deploy with
#   --override-input m2mini-vendorfw path:/boot/vendorfw
# Host doc: docs/hosts/m2mini.md
{ ... }:
{
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
