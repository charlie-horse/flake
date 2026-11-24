# m2mini: an Apple Silicon Mac mini running NixOS through Asahi (Linux for
# Apple Silicon). Built with lib mkServer in parts/hosts.nix (never
# mkHost). Deploy with
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
