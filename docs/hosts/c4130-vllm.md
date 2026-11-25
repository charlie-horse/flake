# vLLM and LMCache on c4130

vLLM is the server that runs a language model on the GPUs and serves an
OpenAI-style API. LMCache stores vLLM's KV cache (the per-request attention
state) outside the GPUs: L1 in RAM, L2 on disk, so repeated prompts start
faster. Both come from flake input `vllm-fork` (the vllm-sm70 repo: modules,
built-in models and per-model fields in its `nix/module.nix`);
`hosts/c4130/vllm/default.nix` sets the host values. The V100 GPUs are
sm_70 (CUDA compute capability 7.0). Deploying:
[c4130.md](c4130.md#deploying-c4130).

## Rules

- **CUDA 12.x only.** CUDA 13 can't build for sm_70. Anything that compiles
  or ships GPU kernels uses CUDA 12.x. `cuobjdump` on LMCache's
  `cuda_ops.so` must show sm_70 images.
- **fp16 only.** Volta has no bf16. Don't serve a model class that needs
  bf16 or FlashInfer.
- **GPU memory budget.** Keep `gpuMemoryUtilization` ≤ 0.91, or long
  prefills run out of GPU memory: the LMCache server uses GPU memory outside
  vLLM's budget.
- **KV must fit one full request.** Otherwise startup fails with "estimated
  maximum model length is N": lower `maxModelLen` or raise utilization
  (within the limit above).
- **RAM.** L1 is pinned RAM, allocated in full at startup, and there is no
  swap. Keep L1 + the model's vLLM load peak + 30 GB under 125 GB. With
  Flint keep `l1SizeGb` ≤ 64.
- **`models.<name>.args` replaces the built-in list**; it doesn't append.
- **Never set `PYTORCH_ALLOC_CONF=expandable_segments:True`.** The LMCache
  server then can't register the KV caches and `vllm` restart-loops.
- Don't put `--attention-backend FLASH_ATTN_V100` or
  `--kernel-config.sm70_skinny_moe` in `args`: vllm-sm70 rejects them.
- Flint and hybrid GDN models need `--separate-object-groups` (LMCache).
  `lmcacheChunkSize` must be a multiple of the model's KV block size
  (vLLM's startup error names it).
- **Restarts.** Restarting `vllm-lmcache` empties L1; restart `vllm` after
  it. Restarting only `vllm` keeps L1.
- **Stopping vllm.** `Restart=on-failure` brings it back after a kill:
  `sudo systemctl kill --signal=SIGKILL vllm && sudo systemctl stop vllm`.
- **vllm.service owns the GPUs.** Before any other GPU job
  (`~admin/vllm-hand`, kernel tests, benchmarks), check
  `systemctl is-active vllm` and stop it. Start it again when done.
- **Clients and Flint reasoning.** Flint always reasons (`enable_thinking`
  does nothing). The reasoning is in `message.reasoning` (streaming:
  `delta.reasoning`); `reasoning_content` is empty. For Qwen entries send
  `chat_template_kwargs.enable_thinking=true`. For the Inkling 2 entries follow
  vllm-sm70's
  [Inkling 2 client rules](https://github.com/charlie-horse/vllm-sm70/blob/main/docs/nix.md#inkling-2).

## Running a custom model

1. **Pick a checkpoint that runs on sm_70.** Its quantization format must be
   one vllm-sm70's patch series supports. Full BF16/FP16 weights must fit
   in the two 32 GB GPUs with room for KV, and run as fp16.
2. **Add `services.vllm-sm70.models."<name>" = { ... };`** in
   `hosts/c4130/vllm/default.nix` on a branch through CI (or a built-in in
   vllm-sm70's `nix/module.nix`). Pin each `downloads` `revision` to a
   commit sha. Hybrid Qwen3.5/3.6/3.8 GDN models need
   `--language-model-only --mamba-cache-mode align` plus their tool and
   reasoning parsers (`qwen3_coder` / `qwen3`) in `args`.
3. **Pre-download** so `switch` doesn't wait on the fetch. As admin on
   c4130, check `ls /var/lib/vllm/models` first, then:
   ```sh
   mkdir -p ~/qwen-staging
   nix shell nixpkgs#python3Packages.huggingface-hub nixpkgs#python3Packages.hf-xet \
     -c hf download <repo> --revision <sha> --local-dir ~/qwen-staging/<dir>
   ```
   Pass `HF_TOKEN` on stdin if the user gives one. Then, with sudo: `mv` the
   dir into `/var/lib/vllm/models/`, `chown -R vllm:vllm` it, and
   `touch <dir>/.complete-<sha>`.
4. **Set `activeModel`** (through CI), then deploy
   ([c4130.md](c4130.md#deploying-c4130)). After the build, check the
   rendered `result/etc/systemd/system/vllm.service`. If vllm doesn't
   restart on its own: `sudo systemctl restart vllm`.
5. **Watch the start:**
   `journalctl _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value vllm)`.
   It takes minutes; the first start of a model also compiles kernels.
   Wait for "Application startup complete" or a Traceback.

## Bumping vllm-fork

In this repo on a branch: `nix flake update vllm-fork` (or merge the
`update.yml` PR that bumps it), CI, merge. Then deploy
([c4130.md](c4130.md#deploying-c4130)) with the RAM guard around the switch.

## Kill switches

To turn one sm_70 feature off for a model, set `VLLM_SM70_<THING>=0` in
`models.<name>.env` and deploy. Env vars can't turn features on; tuning goes
through `--additional-config '{"sm70":{...}}'`. `VLLM_PLUGINS=` set to a
list without `sm70` runs stock vLLM. The variable names are in vllm-sm70.

## Checking LMCache

- Registration: `curl -s 127.0.0.1:8080/status`; `registered_gpu_ids` lists
  one id per GPU.
- Hits: `journalctl -u vllm | grep "External prefix cache hit rate"`. L2
  size: `du -sh /var/lib/lmcache/l2`.
- Admin API:
  `curl 127.0.0.1:8080/{status,config,metrics,env,threads,periodic-threads,quota,lmc_version}`.
  `GET /cache/objects?tier=l2` doesn't work with `fs_native`.
- **Unregistered GPUs.** If `registered_gpu_ids` is empty, or
  `journalctl -u vllm-lmcache` shows `Reaped GPU instance …` or
  `Rejecting STORE for unregistered GPU instance`, restart only `vllm` and
  send one prompt of 256 tokens or more within the hour.
- The dashboard's Config, Meta and Inference tabs don't work; use the admin
  API.
