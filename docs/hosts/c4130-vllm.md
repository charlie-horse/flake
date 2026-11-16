# vLLM and LMCache on c4130

The inference stack on [c4130](c4130.md): one model at a time on both V100s through `vllm.service`, with LMCache as an external KV cache in RAM and on disk. Host basics, deploying and the files on the host are in [c4130.md](c4130.md).

## What runs
- **Flake input `vllm-fork`** = `github:charlie-horse/vllm-sm70/latest` (`flake.nix`; the commit is in `flake.lock`). vllm-sm70 is upstream vLLM v0.33 plus an sm_70 patch series, packaged as a flake (Nix code in its `nix/`, docs in its `nix/README.md`). Its `latest` branch is fast-forwarded only after main CI, the c4130 check, the GPU gate and release sign-off on the same commit. There is no `nixpkgs.follows`: vllm-sm70 builds with its own pinned nixpkgs, so a host nixpkgs bump can't change the gated build.
- vllm-sm70's input `vllm-legacy` (the 1Cat-vLLM source tree `github:charlie-horse/vLLM`, pinned) provides only the Flint checkpoint recipe ([Checkpoint](#checkpoint)).
- **Active model:** `flint` (`services.vllm-sm70.activeModel` in `hosts/c4130/vllm/default.nix`). Only one model fits on the GPUs at a time.
- Attention runs on TRITON_ATTN. `--attention-backend FLASH_ATTN_V100` and `--kernel-config.sm70_skinny_moe` are rejected by vllm-sm70; don't put them in `args`.
- **Second nixpkgs in the lock.** `vllm-legacy` brings its own nixpkgs and a second pyproject-build-systems / pyproject-nix / uv2nix into `flake.lock`. They are only evaluated: nothing is built from them while the checkpoint path is in the store (rooted by the current generation, or substitutable from r440). They are eval-time inputs outside any system closure, so a GC may delete them and the next eval re-fetches them.

## Where things live
- **This repo:** `hosts/c4130/vllm/default.nix` imports `inputs.vllm-fork.nixosModules.vllm` (which also imports `nixosModules.lmcache`) and sets only host values under `services.vllm-sm70` and `services.lmcache-sm70`. `update.yml` re-locks `vllm-fork` with every other input in a Mon/Fri PR that flags vllm-fork bumps ([ci.md](../ci.md)).
- **vllm-sm70:** the vLLM and LMCache NixOS modules, the built-in model list (`nix/module.nix`), the Python env and wrappers, patches (`nix/patches/`).
- **Options.**
  - vllm: `services.vllm-sm70.{enable,activeModel,models,port,firewallInterfaces}`.
  - LMCache: `services.lmcache-sm70.{enable,package,uiPackage,user,homeStateDirectory,environment,chunkSize,port,httpPort,l1SizeGb,l2SizeGb,ui.enable,ui.port,ui.firewallInterfaces}`.
  - The vllm module sets LMCache's `enable` from the active model's `lmcache` field and `chunkSize` from its `lmcacheChunkSize`, and runs it as user `vllm`.
- **Units:** `vllm-model-fetch`, `vllm` (requires `vllm-lmcache`), `vllm-lmcache`, `vllm-lmcache-ui`, and the `vllm-lmcache-l2-prune` timer.
- **Ports:** API 8000 (`port`) on `firewallInterfaces` = `eno1` + `tailscale0` (and bond0 from r440 only, [c4130.md](c4130.md#network)), no API key. LMCache ZMQ 5555 and admin API 8080 on localhost only (admin API has no auth). Dashboard 8081.

### Per-model fields
`services.vllm-sm70.models.<name>`: built-ins are `flint`, `qwen3.6-35b-a3b`, `qwen3.8-27b`; the host adds entries or overrides single fields.
- `downloads`: list of `{ repo, revision, dir }`; the first entry is the served checkpoint, a DFlash2 draft goes after it. Always pin `revision` to a commit sha.
- `path`: serve a Nix store path instead of `downloads`; `vllm-model-fetch` then only checks it exists.
- `args`: model flags. **Setting `args` replaces the built-in list**, it doesn't append (`--dtype half` is in the module's common args).
- `package`, `env` (extra service environment, e.g. kill switches), `maxModelLen` (default 262144), `gpuMemoryUtilization` (default 0.88), `maxNumSeqs`, `asyncScheduling` (default false → `--no-async-scheduling`).
- `lmcache` (default true; false drops `--kv-transfer-config` and removes `vllm-lmcache`, freeing the 64 GB pinned L1), `lmcacheChunkSize` (a multiple of the model's KV block size).

### Weights
- Flint's weights are a Nix store path: the fixed-output checkpoint `/nix/store/0qxvf6z208m6bff62acgwfg6ajhbinpp-flint-nvfp4-modelopt` ([Flint](#flint)).
- HF-downloaded weights (the Qwen entries) live in `/var/lib/vllm/models`, owned by `vllm`, fetched by `vllm-model-fetch`. Pinned repos and revisions are in vllm-sm70's `nix/module.nix`. Before switching to an HF model, check `ls /var/lib/vllm/models`: missing weights are downloaded before vLLM starts (tens of GB), so pre-download them ([Running a custom model](#running-a-custom-model)).

## Flint
`models.flint` serves Flint (RecursiveSI/flint: 39.8B MoE, 2.5B active, NVFP4 W4A16).

### Serving profile
- TP2, 262K context, `gpuMemoryUtilization = 0.90`. KV cache is ~979K tokens.
- **`maxNumSeqs = 20` on c4130** (`hosts/c4130/vllm/default.nix`). Above 2 concurrent sequences the M≤2 decode fast paths (`VLLM_SM70_MODELOPT_NVFP4_GEMV`, `VLLM_SM70_FLINT_MOE_QPN_DECODE`) give way to the batched kernels: more total throughput, less tok/s per request.
- **`args` is set on the host** (it replaces the built-in list): `--kv-cache-dtype auto`, `--enable-prompt-tokens-details`, the `glm47` tool parser, `--reasoning-parser-plugin vllm_sm70.reasoning --reasoning-parser glm47_sm70`, `--exclude-tools-when-tool-choice-none`, default sampling temperature 1.0 / top-p 0.95 / top-k 20 (`--override-generation-config`), and `--hf-overrides` `FlintSm70ForCausalLM`. Without the override vLLM loads upstream's `FlintForCausalLM`, which needs FlashInfer and bf16.
- Env: `CUDA_DEVICE_ORDER=PCI_BUS_ID`, `VLLM_SKIP_P2P_CHECK=0`.
- **Never set `PYTORCH_ALLOC_CONF=expandable_segments:True`.** With expandable segments PyTorch shares CUDA memory over IPC through `pidfd_getfd`, which `kernel.yama.ptrace_scope = 1` denies to the LMCache server (not vLLM's ancestor): `register_kv_caches` fails with `pidfd_getfd: Operation not permitted`, vLLM times out after 300 s and the unit restart-loops.
- `asyncScheduling = true`; the Qwen + LMCache entries run `--no-async-scheduling`. If LMCache loads or stores misbehave, try `asyncScheduling = false` first.
- LMCache on, `lmcacheChunkSize = 256` (a multiple of Flint's block size 16); `--separate-object-groups` stays on since Flint has four KV-cache groups. Works with Flint's sliding-window + full-attention mix.

### Checkpoint
- Built by `nix/flint.nix` of input `vllm-legacy`: fixed-output fetches of the GGUF (`RecursiveSI/flint-nvfp4-gguf`) and the HF metadata (`RecursiveSI/flint`), both pinned, converted on CPU by `vllm.models.flint.convert_gguf` (~3.5 min, ~25 GB peak RAM).
- The checkpoint is fixed-output (`checkpointHash = sha256-HyBUnISsTQXSKmmOft+/fNzrhFLwBJ6imMCa7YRAwoQ=`), so its path depends only on name and hash: `/nix/store/0qxvf6z208m6bff62acgwfg6ajhbinpp-flint-nvfp4-modelopt`. No vllm-sm70, env, LMCache or nixpkgs change moves it, and a missing checkpoint is fetched from r440's cache before anything converts.
- Only the current system generation roots it. **Nothing roots the GGUF** (~23 GB; `~admin/archive/notes/flint-nix/gguf` is a plain symlink), so GC deletes it; it's needed only to re-convert.
- The converter has its own pin (`converterFork`). Bump it, and with it `checkpointHash`, only when the converter or the checkpoint format changes; that re-converts (~4 min) and adds a new 23 GB path, so GC the old one.

### Thinking and the `reasoning` field (client notes)
- Flint always reasons: its chat template ends at `<|assistant|>` with no `enable_thinking` switch, so `chat_template_kwargs.enable_thinking` does nothing.
- Reasoning comes back in **`message.reasoning`** (streaming: `delta.reasoning`); `reasoning_content` is empty. Clients must read `reasoning` (or fall back to it). `~admin/archive/scripts/verify_vllm.py` accepts both; `bench_vllm.py` is broken for Flint ([c4130.md](c4130.md#files-on-the-host)).
- For the Qwen entries send `chat_template_kwargs.enable_thinking=true` to get reasoning.

## Kill switches
Only `VLLM_SM70_<THING>=0` does anything (turns that sm_70 feature off); env vars can't turn features on, and other `VLLM_SM70_*` variables are ignored. Set one per model with `models.<name>.env`. Defaults and tuning go through `--additional-config '{"sm70":{...}}'`. `VLLM_PLUGINS` set to a list without `sm70` (e.g. `VLLM_PLUGINS=`) disables the sm70 plugin and runs stock vLLM.

- Flint: `VLLM_SM70_MODELOPT_NVFP4_GEMV` (dense M≤2 GEMV), `VLLM_SM70_FLINT_MOE_QPN_DECODE` (routed-expert M≤2 decode), `VLLM_SM70_FLINT_QK_ROPE_KV`, `_FLINT_FUSED_ROUTER`, `_FLINT_SAMPLER`, `_FLINT_ATTN_FUSED_DECODE`, `_FLINT_AR_RMSNORM`.
- Other: `VLLM_SM70_FP8_MOE_DECODE`, `_FP8_QPN8`, `_QUANT`, `_FP8_TURBOMIND`, `_DFLASH2_EMULATION`, `_DFLASH2_VERIFIER`, `_SHARED_MOE_OVERLAP`.

## LMCache
- **Connector.** vLLM loads LMCache's own connector via `--kv-transfer-config`: `kv_connector: LMCacheMPConnector`, `kv_connector_module_path: lmcache.integration.vllm.lmcache_mp_connector`, `kv_load_failure_policy: recompute` (a failed or missing chunk is recomputed, not an error), `lmcache.mp.host: tcp://127.0.0.1`, `lmcache.mp.port: 5555`.
- **Server** (`vllm-lmcache`): `lmcache server --host 127.0.0.1 --port 5555 --http-host 127.0.0.1 --http-port 8080 --separate-object-groups --chunk-size <lmcacheChunkSize> --l1-size-gb 64 --eviction-policy LRU --l2-adapter '{"type":"fs_native",...}'`. `--separate-object-groups` is required for hybrid GDN models and for Flint.
- **Tiers.** `l1SizeGb` / `l2SizeGb`, module defaults 64 / 180; c4130 sets 64 / 32 (`hosts/c4130/vllm/default.nix`), so a reduced-memory run needs no module edit.
  - **L1** lives in the `vllm-lmcache` process: 64 GB of pinned RAM, allocated in full at startup (despite the "lazy" allocator name). Keep L1 + the active model's vLLM RAM peak (Flint ~27 GB while loading) + ~30 GB under 125 GB; there's no swap. Lower `l1SizeGb` if the box needs more.
  - **L2** is `/var/lib/lmcache/l2` on the root disk, capped at 32 GB for root disk space.
- **L2 eviction.** LMCache only evicts L2 through its fleet coordinator, which isn't run. The `vllm-lmcache-l2-prune` timer (every minute) deletes the least recently accessed files once usage passes 90% of `l2SizeGb` (28.8 GB), down to 80% (25.6 GB). `fs_native` checks each file exists on every lookup, so a pruned chunk is a miss.
- **Restarts.** Restarting `vllm-lmcache` empties L1 (L2 survives); `vllm` requires it, so restart `vllm` after it. Restarting only `vllm` keeps L1 warm.
- **GPU memory.** The LMCache server takes ~2.2 GiB per GPU (CUDA context plus transfer staging during stores; ~328 MiB idle), outside vLLM's budget: 0.90 utilization plus that is ~31 of 32 GB. Keep `gpuMemoryUtilization` ≤ ~0.91.
- **Packaging.** PyPI has only CUDA 13 LMCache wheels, so it's built from source with `LMCACHE_CUDA_MAJOR=12`. `cuobjdump` on `cuda_ops.so` should show sm_70 images.
- **Checking.**
  - Registration: `curl -s 127.0.0.1:8080/status`; `registered_gpu_ids` should list 2 ids.
  - Hits: `journalctl -u vllm | grep "External prefix cache hit rate"`. L2 size: `du -sh /var/lib/lmcache/l2`.
  - Admin API (`curl 127.0.0.1:8080/...`): `/status` (L1 bytes, L2 adapters, eviction policy, thread health), `/config`, `/metrics`, `/env`, `/threads`, `/periodic-threads`, `/quota`, `/lmc_version`. `GET /cache/objects?tier=l2` doesn't work with `fs_native`.
- **Idle reaper.** The cache server reaps a GPU instance that hasn't pinged for 1 h. vllm-sm70 patches LMCache so workers ping from registration (`nix/patches/lmcache/`). If `registered_gpu_ids` is empty or `journalctl -u vllm-lmcache` shows `Reaped GPU instance …` / `Rejecting STORE for unregistered GPU instance`, restart only `vllm` and send one ≥256-token prompt within the hour.
- CacheBlend doesn't apply to hybrid GDN models; LMCache only does prefix reuse there.

### Dashboard
`vllm-lmcache-ui`, port 8081 (`ui.port`), opened on `ui.firewallInterfaces` = `eno1` + `tailscale0`, no auth; off with `ui.enable = false`. It's `wantedBy = multi-user.target` and requires `vllm-lmcache`, so stopping the cache server stops it too.
- It runs LMCache's own FastAPI app `lmcache.lmcache_frontend` (`${uiPackage}/bin/python -m lmcache.lmcache_frontend.app`). Stateless: it serves `static/index.html` and proxies the server's admin API registered through `--nodes`, which is also the allowlist for its `/proxy/{host}/{port}/…` route (others get a 403).
- `uiPackage` (`lmcacheUi`) is a separate wrapper exposing only `python`, so importing `lmcache` (which pulls in torch) gets the wrapper's `LD_LIBRARY_PATH` without a bare `python` on the system PATH.
- `index.html` loads Bootstrap from `cdn.jsdelivr.net`: the viewing browser needs internet or the page is unstyled.
- Some tabs call endpoint names the MP server doesn't have: Overview asks `api/status` (server: `/status`, so the L1 usage bar never appears), Config asks `conf` (server: `/config`), Meta/Inference ask `meta`/`inference_info` (only exist in-process). Working: Overview (basic), Metrics, Threads, Loglevel, Env. Fixing it means patching `static/js/app.js` and rebuilding lmcache.
- Don't model anything on `lmcache_frontend/run_mp_server_with_frontend.sh`: that's fleet mode (`--no-http`, reports to a central discovery service).

## Open WebUI
Runs in the cluster ([k8s apps](../k8s/apps.md); `k8s/components/apps/open-webui.nix`), at https://chat.neuros.is with authentik SSO (group `local-ai`). It reaches vLLM at `10.0.0.95:<services.vllm-sm70.port>/v1`, so it follows `activeModel`. It is not a NixOS service on c4130; `/var/lib/private/open-webui` holds a backup of its state.

## Running a custom model
1. **Pick a checkpoint that runs on sm_70.** Proven: block-FP8 (128×128) and NVFP4. BF16/FP16 full weights must fit in 2×32 GB with KV left over, and run as fp16. Before a new quantization format, check vllm-sm70's sm_70 patch series supports it.
2. **Add `services.vllm-sm70.models."<name>" = { ... };`** in `hosts/c4130/vllm/default.nix` on a branch through CI (or a built-in in vllm-sm70's `nix/module.nix`). Fields: [Per-model fields](#per-model-fields). Hybrid Qwen3.5/3.6/3.8 GDN models need `--language-model-only --mamba-cache-mode align`, plus their tool/reasoning parsers (`qwen3_coder` / `qwen3`) in `args`. If `lmcacheChunkSize` is wrong, vLLM's startup error names the required value.
3. **Pre-download** so `switch` doesn't block on the fetch (as admin on c4130):
   ```sh
   mkdir -p ~/qwen-staging
   nix shell nixpkgs#python3Packages.huggingface-hub nixpkgs#python3Packages.hf-xet \
     -c hf download <repo> --revision <sha> --local-dir ~/qwen-staging/<dir>
   ```
   Pass `HF_TOKEN` on stdin if the user provides one. Then, with sudo: `mv` the dir into `/var/lib/vllm/models/`, `chown -R vllm:vllm`, and `touch <dir>/.complete-<sha>`.
4. **Set `activeModel`** (through CI), then deploy ([c4130.md](c4130.md#deploying-c4130)); check the rendered `result/etc/systemd/system/vllm.service` after the build. `systemctl restart vllm` if it doesn't restart on its own.
5. Watch the start in the journal (3–6 min; longer on first start because of JIT).

## Bumping vllm-fork
In this repo on a branch: `nix flake update vllm-fork` (or merge the next `update.yml` PR that flags a vllm-fork bump), CI, merge. Then deploy ([c4130.md](c4130.md#deploying-c4130)), with the RAM guard around the switch. There is no rev or hash to edit. Builds run on r440. The Flint checkpoint doesn't move with a bump ([Checkpoint](#checkpoint)).

## Gotchas
- **GPU memory budget.** Keep `gpuMemoryUtilization` ≤ ~0.91 because of LMCache's ~2.2 GiB per GPU, or long prefills OOM.
- **KV must fit one full request.** Startup fails with "estimated maximum model length is N" otherwise: lower `maxModelLen` or raise utilization (within the limit above).
- **Speculative decoding.** DFlash2 drafts (`incoai/*-DFlash2`) speed up decode on the Qwen models and cost KV space.
- **Stopping the service.** `Restart=on-failure` brings `vllm` back after a crash or kill: `systemctl kill --signal=SIGKILL vllm`, then `systemctl stop vllm` (both with sudo).
- **RAM.** L1 + model load peak + page cache must fit in 125 GB with no swap; with Flint keep `l1SizeGb` ≤ 64 (96 runs the box out of memory).

### vllm.service owns the GPUs
Before any GPU job outside the service (the hand harness in `~admin/vllm-hand`, kernel tests, benchmarks), check `systemctl is-active vllm` and stop the service first ([Stopping the service](#gotchas)); start it again when done. Both want both GPUs.
