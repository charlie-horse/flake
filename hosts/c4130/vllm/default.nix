# Host values for the vLLM service. The modules, packages, models and the
# Python environment live in vllm-sm70's flake (input `vllm-fork`, nix/ there).
# Docs: docs/hosts/c4130-vllm.md
{ inputs, ... }:
{
  imports = [
    inputs.vllm-fork.nixosModules.vllm # also imports nixosModules.lmcache
  ];

  services.vllm-sm70 = {
    enable = true;
    # Only one model fits on the GPUs at a time.
    activeModel = "inkling-2-mini-uncensored";
    # Interfaces the API is open on. The API has no authentication.
    firewallInterfaces = [
      "eno1"
      "tailscale0"
    ];
    # Concurrent sequences. Above 2, the M<=2 decode fast paths
    # (VLLM_SM70_MODELOPT_NVFP4_GEMV, ..._MOE_QPN_DECODE) give way to the
    # batched kernels: more total throughput, less speed per request.
    models.flint.maxNumSeqs = 20;
    # Keep at 3 or less: with more concurrent requests its KV cache (vLLM's
    # per-token attention memory) runs out and total throughput drops.
    models."qwen3.8-27b".maxNumSeqs = 3;
    # Serves Flint with vllm-sm70's sm_70 model class (--hf-overrides);
    # upstream's FlintForCausalLM needs FlashInfer and bf16, which V100 lacks.
    # `args` replaces the module's Flint list (nix/module.nix in vllm-sm70),
    # so keep this a copy of it plus --hf-overrides. The module's common
    # args already add `--dtype half`.
    models.flint.args = [
      "--kv-cache-dtype"
      "auto"
      "--enable-prompt-tokens-details"
      "--tool-call-parser"
      "glm47"
      "--reasoning-parser-plugin"
      "vllm_sm70.reasoning"
      "--reasoning-parser"
      "glm47_sm70"
      "--exclude-tools-when-tool-choice-none"
      "--override-generation-config"
      ''{"temperature":1.0,"top_p":0.95,"top_k":20}''
      "--hf-overrides"
      ''{"architectures":["FlintSm70ForCausalLM"]}''
    ];
  };

  # Enabled by the active model's `lmcache` field.
  services.lmcache-sm70 = {
    # L1 is pinned RAM, allocated in full at startup. Keep L1 + the active
    # model's vLLM RAM peak + ~30 GB under 125 GB.
    l1SizeGb = 64;
    # L2 lives on the root disk; keep it small. The pruner trims it to
    # <= 80% of this.
    l2SizeGb = 32;
    # Dashboard (8081); no authentication.
    ui.firewallInterfaces = [
      "eno1"
      "tailscale0"
    ];
  };
}
