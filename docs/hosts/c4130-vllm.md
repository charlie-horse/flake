# vLLM and LMCache on c4130

`hosts/c4130/vllm/default.nix` sets host values for the modules from flake input `vllm-fork` (vllm-sm70: modules, built-in models and per-model fields in its `nix/module.nix`). Deploying: [c4130.md](c4130.md#deploying-c4130).

## Rules
- **CUDA 12.x only.** CUDA 13 can't target the V100s (sm_70); anything that compiles or ships GPU kernels uses CUDA 12.x. LMCache is built from source with `LMCACHE_CUDA_MAJOR=12`; `cuobjdump` on `cuda_ops.so` should show sm_70 images.
- **`--dtype half`.** No bf16 on Volta; the module adds it for every model. Don't serve a model class that needs bf16 or FlashInfer.
- **GPU memory budget.** Keep `gpuMemoryUtilization` ≤ ~0.91: the LMCache server takes ~2.2 GiB per GPU outside vLLM's budget, or long prefills OOM.
- **KV must fit one full request.** Startup fails with "estimated maximum model length is N" otherwise: lower `maxModelLen` or raise utilization (within the limit above).
- **RAM.** LMCache L1 is pinned RAM allocated in full at startup. Keep L1 + the model's vLLM load peak (Flint ~27 GB) + ~30 GB under 125 GB; there is no swap. With Flint keep `l1SizeGb` ≤ 64.
- **`models.<name>.args` replaces the built-in list**, it doesn't append.
- **Never set `PYTORCH_ALLOC_CONF=expandable_segments:True`**: `ptrace_scope = 1` denies `pidfd_getfd` to the LMCache server, `register_kv_caches` fails and the unit restart-loops.
- `--attention-backend FLASH_ATTN_V100` and `--kernel-config.sm70_skinny_moe` are rejected by vllm-sm70; don't put them in `args`.
- `--separate-object-groups` (LMCache) is required for Flint and hybrid GDN models; `lmcacheChunkSize` must be a multiple of the model's KV block size (vLLM's startup error names it).
- **Restarts.** Restarting `vllm-lmcache` empties L1; restart `vllm` after it. Restarting only `vllm` keeps L1 warm.
- **Stopping the service.** `Restart=on-failure` brings `vllm` back after a kill: `sudo systemctl kill --signal=SIGKILL vllm && sudo systemctl stop vllm`.
- **vllm.service owns the GPUs.** Before any GPU job outside it (`~admin/vllm-hand`, kernel tests, benchmarks), check `systemctl is-active vllm` and stop it; start it again when done.
- **Clients and Flint reasoning.** Flint always reasons (`enable_thinking` does nothing); reasoning is in `message.reasoning` (streaming `delta.reasoning`), `reasoning_content` is empty. For Qwen entries send `chat_template_kwargs.enable_thinking=true`.
- **Flint checkpoint.** It is fixed-output (`checkpointHash`), so vllm-sm70 or nixpkgs bumps don't move it. Bump `converterFork` and `checkpointHash` together, only when the converter or format changes; that re-converts (~4 min, ~25 GB RAM) and adds a 23 GB path, so GC the old one.

## Running a custom model
1. **Pick a checkpoint that runs on sm_70.** Proven: block-FP8 (128×128) and NVFP4. BF16/FP16 full weights must fit in 2×32 GB with KV left over, and run as fp16. Check vllm-sm70's sm_70 patch series supports a new quantization format.
2. **Add `services.vllm-sm70.models."<name>" = { ... };`** in `hosts/c4130/vllm/default.nix` on a branch through CI (or a built-in in vllm-sm70's `nix/module.nix`). Pin each `downloads` `revision` to a commit sha. Hybrid Qwen3.5/3.6/3.8 GDN models need `--language-model-only --mamba-cache-mode align`, plus their tool/reasoning parsers (`qwen3_coder` / `qwen3`) in `args`.
3. **Pre-download** so `switch` doesn't block on the fetch (as admin on c4130; check `ls /var/lib/vllm/models` first):
   ```sh
   mkdir -p ~/qwen-staging
   nix shell nixpkgs#python3Packages.huggingface-hub nixpkgs#python3Packages.hf-xet \
     -c hf download <repo> --revision <sha> --local-dir ~/qwen-staging/<dir>
   ```
   Pass `HF_TOKEN` on stdin if the user provides one. Then, with sudo: `mv` the dir into `/var/lib/vllm/models/`, `chown -R vllm:vllm`, and `touch <dir>/.complete-<sha>`.
4. **Set `activeModel`** (through CI), then deploy ([c4130.md](c4130.md#deploying-c4130)); check the rendered `result/etc/systemd/system/vllm.service` after the build. `sudo systemctl restart vllm` if it doesn't restart on its own.
5. Watch the start in the journal (3–6 min; longer on first start because of JIT).

## Bumping vllm-fork
In this repo on a branch: `nix flake update vllm-fork` (or merge the next `update.yml` PR that flags a vllm-fork bump), CI, merge. Then deploy ([c4130.md](c4130.md#deploying-c4130)) with the RAM guard around the switch.

## Kill switches
To turn one sm_70 feature off for a model, set `VLLM_SM70_<THING>=0` in `models.<name>.env` and deploy. Env vars can't turn features on; tuning goes through `--additional-config '{"sm70":{...}}'`. `VLLM_PLUGINS=` (a list without `sm70`) runs stock vLLM. The variable names are in vllm-sm70.

## Checking LMCache
- Registration: `curl -s 127.0.0.1:8080/status`; `registered_gpu_ids` should list 2 ids.
- Hits: `journalctl -u vllm | grep "External prefix cache hit rate"`. L2 size: `du -sh /var/lib/lmcache/l2`.
- Admin API: `curl 127.0.0.1:8080/{status,config,metrics,env,threads,periodic-threads,quota,lmc_version}`. `GET /cache/objects?tier=l2` doesn't work with `fs_native`.
- **Reaped GPU instances.** If `registered_gpu_ids` is empty or `journalctl -u vllm-lmcache` shows `Reaped GPU instance …` / `Rejecting STORE for unregistered GPU instance`, restart only `vllm` and send one ≥256-token prompt within the hour.
- The dashboard's Config, Meta and Inference tabs call endpoints the server doesn't have; use the admin API.
