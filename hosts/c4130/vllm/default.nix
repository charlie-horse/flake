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
    # Up to 20 concurrent sequences (the fork's profile uses 2). KV cache is
    # ~979K tokens, so 20 long requests share it; above 2 the M<=2 decode
    # fast paths (VLLM_SM70_MODELOPT_NVFP4_GEMV, ..._MOE_QPN_DECODE) give way
    # to the batched kernels: more total throughput, less tok/s per request.
    models.flint.maxNumSeqs = 20;
  };

  # Enabled by the active model's `lmcache` field.
  services.lmcache-sm70 = {
    # L1 is pinned RAM, allocated in full at startup. Keep L1 + the active
    # model's vLLM RAM peak + ~30 GB under 125 GB.
    l1SizeGb = 64;
    # L2 on c4130's root disk (91% full). 32 GB since 2026-11-04 (the
    # r440 L2 move was cancelled); the pruner trims to <= 80% of this.
    l2SizeGb = 32;
    # Dashboard (8081); no authentication.
    ui.firewallInterfaces = [ "eno1" "tailscale0" ];
  };
}
