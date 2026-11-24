# c4130: the cluster's GPU node; it serves vLLM (an LLM inference server).
# Docs: docs/hosts/c4130.md (deploy), docs/hosts/c4130-vllm.md (vLLM/LMCache).
#
# Built by lib.system.x86_64-linux.mkServer (parts/hosts.nix): only this
# dir + modules/cluster + modules/server, not the mkHost module tree.
# Needs specialArgs `inputs` with inputs.vllm-fork (vllm-sm70; see flake.nix).
#
# Keep the import order: list-merged options (such as firewall ports)
# follow it.
{ ... }:
{
  imports = [
    ./configuration.nix
    ./hardware-configuration.nix
    ./vllm
    ./builder.nix
  ];
}
