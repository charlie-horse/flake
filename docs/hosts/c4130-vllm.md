# vLLM and LMCache on c4130

The inference stack on [c4130](c4130.md): one model at a time on both V100s through `vllm.service`, with LMCache as an external KV cache in RAM and on disk. Host basics, deploying, the GPU window and the files on the host are in [c4130.md](c4130.md). Dated snapshots and pre-cutover detail: [history/c4130-vllm-state-2026-10.md](../history/c4130-vllm-state-2026-10.md).

## What runs
- **Flake input `vllm-fork`** = `github:charlie-horse/vllm-sm70/latest` (`flake.nix`; locked at `cef0f9e` in `flake.lock`). vllm-sm70 is upstream vLLM v0.33 plus an sm_70 patch series, packaged as a flake (Nix code in its `nix/`, docs in its `nix/README.md`). Its `latest` branch is fast-forwarded only after main CI, the c4130 check, the GPU gate and release sign-off on the same commit. There is no `nixpkgs.follows`: vllm-sm70 builds with its own pinned nixpkgs, so a host nixpkgs bump can't change the gated build.
  > **Conflict (flake.nix, not owned here):** its comment says the input is "pinned to cef0f9e until `latest` is fast-forwarded; then point this at .../latest again", but the URL already is `.../latest` (locked at `cef0f9e`). One of the two is stale.
- c4130 switched to it on 2026-11-12 (`vllm-sm70-service-0.33.0`). It replaced the 1Cat-vLLM source fork `github:charlie-horse/vLLM` (the "fork"), which survives only as vllm-sm70's input `vllm-legacy` (pinned `cf9492a`) for the Flint checkpoint recipe.
- **Active model:** `flint` (`services.vllm-sm70.activeModel` in `hosts/c4130/vllm/default.nix`). Only one model fits on the GPUs at a time.
- **Dropped fork-only flags** (`TODO(sm70-attn)` / `TODO(sm70-moe)` in vllm-sm70's `nix/module.nix`): `--kernel-config.sm70_skinny_moe false` (Flint) and `--attention-backend FLASH_ATTN_V100` (Qwen3.8-27B and its DFlash draft). Upstream v0.33 rejects them until the patch series adds them, so vLLM uses TRITON_ATTN.
- **Second nixpkgs in the lock.** `vllm-legacy` brings its own nixpkgs (`c3eea5b`) and a second pyproject-build-systems / pyproject-nix / uv2nix into `flake.lock`. They are only evaluated: nothing is built from them while the checkpoint path is in the store (rooted by the current generation, or substitutable from r440). They are eval-time inputs outside any system closure, so a GC may delete them and the next eval re-fetches them.

## Where things live
- **This repo:** `hosts/c4130/vllm/default.nix` imports `inputs.vllm-fork.nixosModules.vllm` (which also imports `nixosModules.lmcache`) and sets only host values under `services.vllm-sm70` and `services.lmcache-sm70`. `update.yml` re-locks `vllm-fork` with every other input in a Mon/Fri PR that flags vllm-fork bumps ([ci.md](../ci.md)).
- **vllm-sm70:** the vLLM and LMCache NixOS modules, the built-in model list (`nix/module.nix`), the Python env and wrappers, patches (`nix/patches/`).
- **Options.**
  - vllm: `services.vllm-sm70.{enable,activeModel,models,port,firewallInterfaces}`.
  - LMCache: `services.lmcache-sm70.{enable,package,uiPackage,user,homeStateDirectory,environment,chunkSize,port,httpPort,l1SizeGb,l2SizeGb,ui.enable,ui.port,ui.firewallInterfaces}`.
  - The vllm module sets LMCache's `enable` from the active model's `lmcache` field and `chunkSize` from its `lmcacheChunkSize`, and runs it as user `vllm`.
- **Units:** `vllm-model-fetch`, `vllm` (requires `vllm-lmcache`), `vllm-lmcache`, `vllm-lmcache-ui`, and the `vllm-lmcache-l2-prune` timer.
- **Ports:** API 8000 (`port`) on `firewallInterfaces` = `eno1` + `tailscale0` (and bond0 from r440 only, [c4130.md](c4130.md#network)), no API key. LMCache ZMQ 5555 and admin API 8080 on localhost only (admin API has no auth). Dashboard 8081.

> **Unverified:** the module internals below (option names, units, connector config, LMCache flags, per-model fields) were documented against the old fork. vllm-sm70 keeps the same option names; the rest was not re-checked in its source after the cutover.

### Per-model fields
`services.vllm-sm70.models.<name>`: built-ins are `flint`, `qwen3.6-35b-a3b`, `qwen3.8-27b`; the host adds entries or overrides single fields.
- `downloads`: list of `{ repo, revision, dir }`; the first entry is the served checkpoint, a DFlash2 draft goes after it. Always pin `revision` to a commit sha.
- `path`: serve a Nix store path instead of `downloads`; `vllm-model-fetch` then only checks it exists.
- `args`: model flags. **Setting `args` replaces the built-in list**, it doesn't append (`--dtype half` is in the module's common args).
- `package`, `env` (extra service environment, e.g. kill switches), `maxModelLen` (default 262144), `gpuMemoryUtilization` (default 0.88), `maxNumSeqs`, `asyncScheduling` (default false → `--no-async-scheduling`).
- `lmcache` (default true; false drops `--kv-transfer-config` and removes `vllm-lmcache`, freeing the 64 GB pinned L1), `lmcacheChunkSize` (a multiple of the model's KV block size).

### Weights
- Flint's weights are a Nix store path: the fixed-output checkpoint `/nix/store/0qxvf6z208m6bff62acgwfg6ajhbinpp-flint-nvfp4-modelopt` ([Flint](#flint)).
- HF-downloaded weights (the Qwen entries) live in `/var/lib/vllm/models`, owned by `vllm`, fetched by `vllm-model-fetch`. Pinned repos and revisions are in vllm-sm70's `nix/module.nix`.
  > **Unverified:** that directory was emptied on 2026-11-04 (Qwen3.6/3.8 FP8 weights and both DFlash2 drafts deleted), so switching to a Qwen model re-downloads ~70 GB first. Check `ls /var/lib/vllm/models` before relying on it.

## Flint
`models.flint` serves Flint (RecursiveSI/flint: 39.8B MoE, 2.5B active, NVFP4 W4A16).

### Serving profile
- TP2, 262K context, `gpuMemoryUtilization = 0.90`. KV cache is ~979K tokens.
- **`maxNumSeqs = 20` on c4130** (`hosts/c4130/vllm/default.nix`; the old fork's `scripts/serve_flint_nvfp4_v100_pcie.sh` profile uses 2). Above 2 concurrent sequences the M≤2 decode fast paths (`VLLM_SM70_MODELOPT_NVFP4_GEMV`, `VLLM_SM70_FLINT_MOE_QPN_DECODE`) give way to the batched kernels: more total throughput, less tok/s per request.
- **`args` is set on the host** (it replaces the built-in list): `--kv-cache-dtype auto`, `--enable-prompt-tokens-details`, the `glm47` tool parser, `--reasoning-parser-plugin vllm_sm70.reasoning --reasoning-parser glm47_sm70`, `--exclude-tools-when-tool-choice-none`, default sampling temperature 1.0 / top-p 0.95 / top-k 20 (`--override-generation-config`), and `--hf-overrides` `FlintSm70ForCausalLM`. Without the override vLLM loads upstream's `FlintForCausalLM`, which needs FlashInfer and bf16. The host list can go once vllm-sm70's built-in Flint entry carries the override (`TODO(cutover)`, vllm-sm70 #36).
- Env: `CUDA_DEVICE_ORDER=PCI_BUS_ID`, `VLLM_SKIP_P2P_CHECK=0`.
- **No `PYTORCH_ALLOC_CONF=expandable_segments:True`**, unlike the fork's serve script. With expandable segments PyTorch shares CUDA memory over IPC through `pidfd_getfd`, which `kernel.yama.ptrace_scope = 1` denies to the LMCache server (not vLLM's ancestor): `register_kv_caches` fails with `pidfd_getfd: Operation not permitted`, vLLM times out after 300 s and the unit restart-loops. Dropping it cost 0.25% of KV and no measurable decode speed.
- `asyncScheduling = true` (the tuned profile); the Qwen + LMCache entries run `--no-async-scheduling`. If LMCache loads or stores misbehave, try `asyncScheduling = false` first.
- LMCache on, `lmcacheChunkSize = 256` (a multiple of Flint's block size 16); `--separate-object-groups` stays on since Flint has four KV-cache groups. Works with Flint's sliding-window + full-attention mix.

### Checkpoint
- Built by the old fork's `nix/flint.nix` (through `vllm-legacy`): fixed-output fetches of the GGUF (`RecursiveSI/flint-nvfp4-gguf`) and the HF metadata (`RecursiveSI/flint`), both pinned, converted on CPU by the fork's `vllm.models.flint.convert_gguf` (~3.5 min, ~25 GB peak RAM).
- The checkpoint is fixed-output (`checkpointHash = sha256-HyBUnISsTQXSKmmOft+/fNzrhFLwBJ6imMCa7YRAwoQ=`), so its path depends only on name and hash: `/nix/store/0qxvf6z208m6bff62acgwfg6ajhbinpp-flint-nvfp4-modelopt`. No fork, env, LMCache or nixpkgs change moves it, and a missing checkpoint is fetched from r440's cache before anything converts.
- Only the current system generation roots it. **Nothing roots the GGUF** (~23 GB; `~admin/archive/notes/flint-nix/gguf` is a plain symlink), so GC deletes it. That's fine: it's needed only to re-convert.
- The converter has its own pin (`converterFork`, `f66728d`). Bump it, and with it `checkpointHash`, only when the converter or the checkpoint format changes; that re-converts (~4 min) and adds a new 23 GB path, so GC the old one.

### Thinking and the `reasoning` field (client notes)
- Flint always reasons: its chat template ends at `<|assistant|>` with no `enable_thinking` switch, so `chat_template_kwargs.enable_thinking` does nothing.
- Since the cutover (vLLM 0.33, parser `glm47_sm70`) reasoning comes back in **`message.reasoning`** (streaming: `delta.reasoning`); `reasoning_content` is empty. Clients must read `reasoning` (or fall back to it). `~admin/archive/scripts/verify_vllm.py` accepts both; `bench_vllm.py` is broken for Flint ([c4130.md](c4130.md#files-on-the-host)).
- The Qwen entries default to `enable_thinking` false; send `chat_template_kwargs.enable_thinking=true` to get reasoning.
  > **Unverified:** that default was 1Cat's; not re-checked on vllm-sm70.

## Kill switches
Only `VLLM_SM70_<THING>=0` does anything (turns that sm_70 feature off); env vars can't turn features on, and other `VLLM_SM70_*` variables from the old fork are ignored. Set one per model with `models.<name>.env`. Defaults and tuning go through `--additional-config '{"sm70":{...}}'`. `VLLM_PLUGINS` set to a list without `sm70` (e.g. `VLLM_PLUGINS=`) disables the sm70 plugin and runs stock vLLM.

| Variable | Origin |
|---|---|
| `VLLM_SM70_MODELOPT_NVFP4_GEMV` (dense M≤2 GEMV) | Flint, kept from the fork |
| `VLLM_SM70_FLINT_MOE_QPN_DECODE` (routed-expert M≤2 decode) | Flint, kept from the fork |
| `VLLM_SM70_FLINT_QK_ROPE_KV`, `_FLINT_FUSED_ROUTER`, `_FLINT_SAMPLER`, `_FLINT_ATTN_FUSED_DECODE`, `_FLINT_AR_RMSNORM` | Flint, kept from the fork |
| `VLLM_SM70_FP8_MOE_DECODE`, `_FP8_QPN8` (new meaning, not the fork's TP4 one), `_QUANT`, `_FP8_TURBOMIND`, `_DFLASH2_EMULATION`, `_DFLASH2_VERIFIER`, `_SHARED_MOE_OVERLAP` | new in vllm-sm70 |

## LMCache
- **Connector.** vLLM loads LMCache's own connector via `--kv-transfer-config`: `kv_connector: LMCacheMPConnector`, `kv_connector_module_path: lmcache.integration.vllm.lmcache_mp_connector`, `kv_load_failure_policy: recompute` (a failed or missing chunk is recomputed, not an error), `lmcache.mp.host: tcp://127.0.0.1`, `lmcache.mp.port: 5555`.
- **Server** (`vllm-lmcache`): `lmcache server --host 127.0.0.1 --port 5555 --http-host 127.0.0.1 --http-port 8080 --separate-object-groups --chunk-size <lmcacheChunkSize> --l1-size-gb 64 --eviction-policy LRU --l2-adapter '{"type":"fs_native",...}'`. `--separate-object-groups` is required for hybrid GDN models and for Flint.
- **Tiers.** `l1SizeGb` / `l2SizeGb`, module defaults 64 / 180; c4130 sets 64 / 32 (`hosts/c4130/vllm/default.nix`), so a reduced-memory run needs no module edit.
  - **L1** lives in the `vllm-lmcache` process: 64 GB of pinned RAM, allocated in full at startup (despite the "lazy" allocator name). Keep L1 + the active model's vLLM RAM peak (Flint ~27 GB while loading) + ~30 GB under 125 GB; there's no swap. Lower `l1SizeGb` if the box needs more.
  - **L2** is `/var/lib/lmcache/l2` on the root disk, capped at 32 GB because of root disk space.
- **L2 eviction.** LMCache only evicts L2 through its fleet coordinator, which isn't run. The `vllm-lmcache-l2-prune` timer (every minute) deletes the least recently accessed files once usage passes 90% of `l2SizeGb` (28.8 GB), down to 80% (25.6 GB). Safe because `fs_native` checks each file exists on every lookup, so a pruned chunk is a miss.
- **Restarts.** Restarting `vllm-lmcache` empties L1 (L2 survives); `vllm` requires it, so restart `vllm` after it. Restarting only `vllm` keeps L1 warm.
- **GPU memory.** The LMCache server takes ~2.2 GiB per GPU (CUDA context plus transfer staging during stores; ~328 MiB idle), outside vLLM's budget: 0.90 utilization plus that is ~31 of 32 GB. Keep `gpuMemoryUtilization` ≤ ~0.91.
- **Packaging.** PyPI has only CUDA 13 LMCache wheels, so it's built from source with `LMCACHE_CUDA_MAJOR=12`. `cuobjdump` on `cuda_ops.so` should show sm_70 images.
- **Checking.**
  - Registration: `curl -s 127.0.0.1:8080/status`; `registered_gpu_ids` should list 2 ids.
  - Hits: `journalctl -u vllm | grep "External prefix cache hit rate"`. L2 size: `du -sh /var/lib/lmcache/l2`.
  - Admin API (`curl 127.0.0.1:8080/...`): `/status` (L1 bytes, L2 adapters, eviction policy, thread health), `/config`, `/metrics`, `/env`, `/threads`, `/periodic-threads`, `/quota`, `/lmc_version`. `GET /cache/objects?tier=l2` doesn't work with `fs_native`.
- **1-hour reaper.** In LMCache 0.5.6 (the old fork) each vLLM worker started pinging the cache server only on its first store (a prompt of at least one 256-token chunk). With no such prompt within 1 h of a vllm start, the server reaps both GPU instances (`Reaped GPU instance …: silent for 3600.1s (pinged=False)` in `journalctl -u vllm-lmcache`); every later store is rejected (`Rejecting STORE for unregistered GPU instance`) until vllm restarts. A busy server is unaffected. vllm-sm70 carries the heartbeat-from-registration fix (`nix/patches/lmcache/`, vllm-sm70 PR #10).
  > **Unverified:** that the fix is active on c4130. After a vllm start, check `registered_gpu_ids` more than an hour later with no long prompt in between. If it's empty, the workaround is restarting only `vllm` and sending one ≥256-token prompt within the hour.
- CacheBlend doesn't apply to hybrid GDN models; LMCache only does prefix reuse there.

### Dashboard
`vllm-lmcache-ui`, port 8081 (`ui.port`), opened on `ui.firewallInterfaces` = `eno1` + `tailscale0`, no auth; off with `ui.enable = false`. It's `wantedBy = multi-user.target` and requires `vllm-lmcache`, so stopping the cache server stops it too.
- It runs LMCache's own FastAPI app `lmcache.lmcache_frontend` (`${uiPackage}/bin/python -m lmcache.lmcache_frontend.app`). Stateless: it serves `static/index.html` and proxies the server's admin API registered through `--nodes`, which is also the allowlist for its `/proxy/{host}/{port}/…` route (others get a 403).
- `uiPackage` (`lmcacheUi`) is a separate wrapper exposing only `python`, so importing `lmcache` (which pulls in torch) gets the wrapper's `LD_LIBRARY_PATH` without a bare `python` on the system PATH.
- `index.html` loads Bootstrap from `cdn.jsdelivr.net`: the viewing browser needs internet or the page is unstyled.
- In 0.5.6 three tabs call endpoint names the MP server no longer has: Overview asks `api/status` (server: `/status`, so the L1 usage bar never appears), Config asks `conf` (server: `/config`), Meta/Inference ask `meta`/`inference_info` (only exist in-process). Working: Overview (basic), Metrics, Threads, Loglevel, Env. Fixing it means patching `static/js/app.js` and rebuilding lmcache.
- Don't model anything on `lmcache_frontend/run_mp_server_with_frontend.sh`: that's fleet mode (`--no-http`, reports to a central discovery service).

## Open WebUI
Runs in the cluster since 2026-11-10 ([k8s apps](../k8s/apps.md); `k8s/components/apps/open-webui.nix`, image `v0.12.2`), at https://chat.neuros.is with authentik SSO (group `local-ai`). It reaches vLLM at `10.0.0.95:<services.vllm-sm70.port>/v1`, so it follows `activeModel`. It's no longer a NixOS service on c4130, and port 8082 is closed; the old state in `/var/lib/private/open-webui` stays as a backup.
> **Unverified:** Open WebUI v0.12.2 is expected to read Flint's `reasoning` field but wasn't re-checked after the cutover.

## Running a custom model
1. **Pick a checkpoint that runs on sm_70.** Proven: block-FP8 (128×128) and NVFP4. BF16/FP16 full weights must fit in 2×32 GB with KV left over, and run as fp16. Before a new quantization format, check vllm-sm70's sm_70 patch series supports it.
   > **Unverified:** the format list (also AWQ/W4A16, compressed-tensors, GGUF) was 1Cat's; vllm-sm70 support not checked.
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
- **GPU memory budget.** Keep `gpuMemoryUtilization` ≤ ~0.91 because of LMCache's ~2.2 GiB per GPU, or long prefills OOM (with 1Cat this was inside its FP8 workspace).
- **KV must fit one full request.** Startup fails with "estimated maximum model length is N" otherwise: lower `maxModelLen` or raise utilization (within the limit above).
- **Speculative decoding.** DFlash2 drafts (`incoai/*-DFlash2`) gave +70% decode on Qwen3.6-35B (111 vs 66 tok/s at 4K, on 1Cat). They cost KV space.
- **Stopping the service.** `Restart=on-failure` brings `vllm` back after a crash or kill: `systemctl kill --signal=SIGKILL vllm`, then `systemctl stop vllm` (both with sudo).
- **RAM.** L1 + model load peak + page cache must fit in 125 GB with no swap; at L1 96 GB Flint's load ran the box out of memory ([history](../history/c4130-vllm-state-2026-10.md)).

### vllm.service owns the GPUs
Before any GPU job outside the service (the hand harness in `~admin/vllm-hand`, kernel tests, benchmarks), check `systemctl is-active vllm` and stop the service first ([Stopping the service](#gotchas)); start it again when done. Both want both GPUs. The old `~/flint/gpu.lock` convention is retired (the service never took it). At night the [GPU window](c4130.md#gpu-window) stops vllm for you.
