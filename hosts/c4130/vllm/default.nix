# Host values for the vLLM service. The modules, packages, models and the
# Python environment live in the fork's flake (input `vllm-fork`, nix/ there).
{ inputs, ... }:
{
  imports = [
    inputs.vllm-fork.nixosModules.vllm # also imports nixosModules.lmcache
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
    # Serve Flint with vllm-sm70's sm_70 model class. Without the override
    # vLLM loads upstream's FlintForCausalLM, which needs FlashInfer and bf16
    # (not available on V100). `args` replaces the built-in list, so this is
    # the module's Flint list (parser flags: vllm_sm70.reasoning plugin +
    # glm47_sm70, as in nix/module.nix) plus --hf-overrides; `--dtype half` is already
    # in the module's common args for every model.
    # TODO(cutover): needs FlintSm70ForCausalLM registered by the sm70 plugin
    # (vllm-sm70 #36). Move the override into vllm-sm70's built-in Flint entry
    # once that lands, then drop this block.
    models.flint.args = [
      "--kv-cache-dtype" "auto"
      "--enable-prompt-tokens-details"
      "--tool-call-parser" "glm47"
      "--reasoning-parser-plugin" "vllm_sm70.reasoning"
      "--reasoning-parser" "glm47_sm70"
      "--exclude-tools-when-tool-choice-none"
      "--override-generation-config" ''{"temperature":1.0,"top_p":0.95,"top_k":20}''
      "--hf-overrides" ''{"architectures":["FlintSm70ForCausalLM"]}''
    ];
  };

  # Enabled by the active model's `lmcache` field.
  services.lmcache-sm70 = {
    # L1 is pinned RAM, allocated in full at startup. Keep L1 + the active
    # model's vLLM RAM peak + ~30 GB under 125 GB.
    l1SizeGb = 64;
    # L2 on c4130's root disk (~41% full on 2026-11-05). 32 GB since
    # 2026-11-04 (the r440 L2 move was cancelled); the pruner trims to <= 80%
    # of this.
    l2SizeGb = 32;
    # Dashboard (8081); no authentication.
    ui.firewallInterfaces = [ "eno1" "tailscale0" ];
  };
}
