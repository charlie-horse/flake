# Host values for the vLLM service. The modules, packages, models and the
# Python environment live in the fork's flake (input `vllm-fork`, nix/ there).
{ inputs, ... }:
{
  imports = [
    inputs.vllm-fork.nixosModules.vllm # also imports nixosModules.lmcache
    ./open-webui.nix
  ];

  services.vllm-sm70 = {
    enable = true;
    # Only one model fits on the GPUs at a time.
    activeModel = "flint";
    # API (8000); no authentication.
    firewallInterfaces = [ "eno1" "tailscale0" ];
  };

  # Enabled by the active model's `lmcache` field.
  services.lmcache-sm70 = {
    # L1 is pinned RAM, allocated in full at startup. Keep L1 + the active
    # model's vLLM RAM peak + ~30 GB under 125 GB.
    l1SizeGb = 64;
    l2SizeGb = 100;
    # Dashboard (8081); no authentication.
    ui.firewallInterfaces = [ "eno1" "tailscale0" ];
  };
}
