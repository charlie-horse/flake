# c4130: 2x V100 vLLM inference host (x86_64, NixOS 26.05).
# Docs: docs/hosts/c4130.md (host), docs/hosts/c4130-vllm.md (vLLM/LMCache).
#
# Built by lib.system.x86_64-linux.mkServer (parts/hosts.nix): only this
# dir + modules/cluster + modules/server, not the mkHost module tree.
# Needs specialArgs `inputs` with inputs.vllm-fork
# (github:charlie-horse/vllm-sm70; no nixpkgs.follows, see flake.nix).
#
# Module order matters for byte-identical output (list-merged options such
# as firewall ports); keep it as in the host flake.
{ ... }:
{
  imports = [
    ./configuration.nix
    ./hardware-configuration.nix
    ./vllm
    ./builder.nix
    ./gpu-window.nix
  ];
}
