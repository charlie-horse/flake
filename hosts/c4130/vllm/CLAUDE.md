# c4130 vLLM inference host

c4130 is one of the three NixOS 26.05 cluster servers (c4130, r440, m2mini). Its config is `hosts/c4130/` in this repo (charlie-horse/flake). On every server `/etc/nixos` is a git checkout of `main` (charlie:root, 0755) and the only checkout; `~/src/flake` is gone. The vLLM setup comes from the fork's flake (flake input `vllm-fork`, github.com/charlie-horse/vLLM, Nix code under `nix/`); `hosts/c4130/vllm/` only sets the host values. Old `/etc/nixos` backups are in `~/archive/nixos-backups/` (see "Files on the host").

## Access from a cloud session
- Tailscale isn't preinstalled. Download the static `tailscale_<ver>_amd64.tgz` from pkgs.tailscale.com (piping the install script into `sh` gets blocked), then run `tailscaled --tun=userspace-networking --statedir=/var/lib/tailscale --socket=/var/run/tailscale/tailscaled.sock` in the background and `tailscale up --authkey="$TAIL_AUTH_KEY" --hostname=flake-cloud --accept-routes`. `TAIL_AUTH_KEY` is in the environment. The node can get logged out after container restarts; if `status` shows no peers, run `up` again.
- Only SSH to the hosts when the user has allowed it for the task.
- SSH goes through Tailscale SSH as `charlie`: `ssh -o ProxyCommand="tailscale --socket=… nc %h %p" charlie@c4130` (install `openssh-client` with apt).
- SSH to c4130 over the tailnet uses Tailscale SSH (auth method 'none'). The tailnet ACLs are reviewed and intended by the owner; don't flag it as a security issue.
- `sudo` needs charlie's password. Ask the user for it, and pass it on stdin (`sudo -S`), never on a command line. Secrets never go in git or on a command line. `/etc/nixos` is writable by charlie, so `git pull` and building need no sudo; `nixos-rebuild switch` and `journalctl -u vllm` do.
- etcd and the k8s apiserver also run on this box (3-member etcd with r440 and m2mini). Switch one host at a time and run the etcd health check from `docs/cluster-handoff.md` after each; never take two members down together, or etcd loses quorum. `switch` exiting with status 4 means a unit failed (read `systemctl --failed`). Leave etcd alone unless the user asks.
- The cluster PKI (CA keys) lives only on r440 (`~/.local/share/cluster-pki/solaris`); never copy it elsewhere or into git.

## Deploying
- Every change, including a model entry or a fork re-lock, goes through this repo: branch → CI → merge. Then on c4130: `cd /etc/nixos && git pull && sudo nixos-rebuild switch --flake /etc/nixos#c4130`. Never run `nix flake update` or edit files inside `/etc/nixos` on the host.
- **c4130 runs main** (`8a54e1f`, fork `cf9492a`) since 2026-11-04 16:06 EST (system-42). Its root disk is ~41% full (207 GB free on 2026-11-05). GC old generations before any c4130 switch (Charlie's rule); with the disk at 41% it's quick, and after a switch that replaces the checkpoint, GC the old 23 GB path.
- Builds happen on r440 only (see "Remote builder and cache"): c4130 has `max-jobs = 0`; r440 builds 2 jobs × 8 cores, with nix-daemon capped at 36G and zram swap.

## Hardware
- 2× Tesla V100-PCIe-32GB, both sm_70, on the same PCIe switch with no NVLink. Driver 580, the last driver branch for Volta.
- 48 threads, 125 GB RAM, and SATA SSD RAID1 (root 41% full, 207 GB free, on 2026-11-05).
- **CUDA 13 can't target sm_70.** Anything that compiles or ships GPU kernels must use CUDA 12.x (the stack uses 12.8). No bf16 support, so run everything as `--dtype half`.

## Stack (fork repo `nix/`, consumed as flake input `vllm-fork`)
- **Where things live.**
  - Fork repo (github.com/charlie-horse/vLLM): `flake.nix` exports only `packages.x86_64-linux.vllm` (= `default`, the wrapped sm_70 build) and `nixosModules.vllm` (= `default`, imports `lmcache`) + `nixosModules.lmcache`. Weights, the wheel env and the LMCache UI are internal to the modules. `nix/module.nix` (vllm service and built-in models), `nix/lmcache.nix` (LMCache server, dashboard, L2 pruner), `nix/packages-module.nix` (builds the package set once with the host's `pkgs` for both modules), `nix/package.nix` (env + wrappers), `nix/flint.nix` (sm_70 tree, converter, checkpoint), `nix/source.nix` (the serving tree's source: the repo minus `nix/`, `flake.nix`, `flake.lock`), `nix/pyenv/`, `nix/README.md`.
  - Host (this repo): root `flake.nix` (input `vllm-fork.url = "github:charlie-horse/vLLM/latest"`; after cutover `github:charlie-horse/vllm-sm70`, see "After cutover", `vllm-fork.inputs.nixpkgs.follows = "nixpkgs"`; `update.yml` re-locks it daily), `hosts/c4130/vllm/default.nix` (imports `inputs.vllm-fork.nixosModules.vllm` and `./open-webui.nix`; sets only host values under `services.vllm-sm70` and `services.lmcache-sm70`), `hosts/c4130/vllm/open-webui.nix`, and this CLAUDE.md.
  - vllm options: `services.vllm-sm70.{enable,activeModel,models,port,firewallInterfaces}`. LMCache options: `services.lmcache-sm70.{enable,package,uiPackage,user,homeStateDirectory,environment,chunkSize,port,httpPort,l1SizeGb,l2SizeGb,ui.enable,ui.port,ui.firewallInterfaces}`. The vllm module sets `enable` from the active model's `lmcache` field, `chunkSize` from `lmcacheChunkSize`, and runs it as user `vllm`. The old `c4130.vllm.activeModel` / `c4130.vllm.kvTiers.*` names still work as renamed aliases (with a warning).
  - nixpkgs is shared with the host via `follows`. pyproject-nix, uv2nix and build-system-pkgs are pinned by the fork's own `flake.lock`; bump them in the fork with `nix flake update` there.
- `nix/pyenv/pyproject.toml` + `uv.lock`: the Python environment, built by Nix through uv2nix.
  - 1Cat-vLLM 1.5.1 (a Volta fork of vLLM) comes from its SM70 release wheel.
  - torch 2.10.0+cu128 (includes sm_70).
  - LMCache 0.5.6 is built from its PyPI sdist with `LMCACHE_CUDA_MAJOR=12`. Its deps are declared statically in `[[tool.uv.dependency-metadata]]`, with numpy/prometheus/otel upper bounds relaxed.
  - Re-lock in the fork repo's `nix/pyenv` with `uv lock --python 3.12` (uv isn't on c4130), push, then bump the fork (see "Bumping the fork").
- `nix/package.nix`: builds the env and wraps `vllm`, `hf` and `lmcache` with the runtime setup:
  - `LD_LIBRARY_PATH` covering the driver libs, the nvidia-* wheel libs, `tvm_ffi`, and `z3`.
  - `CUDA_HOME` pointing at the CUDA 12.8 toolkit, plus `NVCC_PREPEND_FLAGS=-I<toolkit>/include`, which the JIT needs.
  - It also holds the LMCache source-build override.
- `nix/module.nix`:
  - A `models` option (built-ins: `flint`, `qwen3.6-35b-a3b`, `qwen3.8-27b`; hosts add entries or override single fields), with `services.vllm-sm70.activeModel` selecting which model runs. Only one fits on the GPUs at a time.
  - Systemd units: `vllm-model-fetch` and `vllm`. `nix/lmcache.nix` adds `vllm-lmcache` (L1 = 64 GB pinned RAM, allocated in full at startup; L2 = `/var/lib/lmcache/l2` capped at 32 GB by the `vllm-lmcache-l2-prune` timer) and `vllm-lmcache-ui`.
  - Port 8000 (`port`) is open on `services.vllm-sm70.firewallInterfaces` (it opens only that port), here `eno1` (LAN `10.0.0.95`) and `tailscale0`, with no API key (the user relies on network policy instead).
- Weights: Flint's are a Nix store path (see "Flint"). HF-downloaded weights (the Qwen entries) live in `/var/lib/vllm/models`, owned by `vllm`. That directory has been empty since 2026-11-04 (the Qwen3.6/3.8 FP8 weights and both DFlash2 drafts were deleted), so switching to a Qwen model re-downloads them first: ~70 GB, during `vllm-model-fetch`. The pinned repos and revisions are in the fork's `nix/module.nix`.
- Check scripts are in `~/archive/scripts` on c4130: `verify_vllm.py` (models / tool calls / recall), `bench_vllm.py` (TTFT and decode tok/s; set `MODEL=`; **broken for Flint**: it counts only `content` tokens, and Flint always reasons first), and `kvtier_test.py` (cold vs L1 vs L2); also `build-lmcache.sh`, `dflash36-test.sh`, `mtp-test.sh`. The last kvtier results are `~/archive/results/kvtier_results.json`.

## LMCache details
- **Connector.** vLLM loads LMCache's own connector, not the one bundled in 1Cat, which targets an older LMCache API (`lmcache.v1.multiprocess.mq`/`protocol` no longer exist). In `--kv-transfer-config`:
  - `kv_connector: LMCacheMPConnector`
  - `kv_connector_module_path: lmcache.integration.vllm.lmcache_mp_connector` (1Cat's factory checks the module path before its own registry)
  - `kv_load_failure_policy: recompute`, so a failed or missing chunk is recomputed instead of erroring
  - `lmcache.mp.host: tcp://127.0.0.1`, `lmcache.mp.port: 5555`
- **Server flags** (`vllm-lmcache`): `lmcache server --host 127.0.0.1 --port 5555 --http-host 127.0.0.1 --http-port 8080 --separate-object-groups --chunk-size <model.lmcacheChunkSize> --l1-size-gb 64 --eviction-policy LRU --l2-adapter '{"type":"fs_native",...}'`.
  - `--separate-object-groups` is required for hybrid GDN models.
  - The ZMQ control channel (5555) and the admin API (8080) bind localhost only; the admin API has no authentication.
  - Ports are `services.lmcache-sm70.port` / `.httpPort` (5555 / 8080). Tier sizes are `services.lmcache-sm70.l1SizeGb` / `.l2SizeGb` (module defaults 64 / 180; c4130 sets 64 / 32 in `hosts/c4130/vllm/default.nix`: 100 since 2026-10-31, when L2 at 140 GB filled the root disk, and 32 since 2026-11-04 with the root disk at 91%), so a reduced-memory run needs no edit to the module.
- **Dashboard** (`vllm-lmcache-ui`, port 8081 = `services.lmcache-sm70.ui.port`, opened on `services.lmcache-sm70.ui.firewallInterfaces`, here `eno1` + `tailscale0`, no auth; turn off with `ui.enable = false`). `lmcache.lmcache_frontend` — LMCache's own FastAPI app, run as `${uiPackage}/bin/python -m lmcache.lmcache_frontend.app`. It holds no state: it serves `static/index.html` and proxies the MP server's admin API, registered through `--nodes` (which is also the allowlist its `/proxy/{host}/{port}/…` route checks, so unregistered targets get a 403).
  - `uiPackage` defaults to `lmcacheUi`, a separate `mkWrapped` in `nix/package.nix` exposing only `python`. The app is pure FastAPI but importing `lmcache` pulls in torch, so it needs the wrapper's `LD_LIBRARY_PATH`; keeping it out of `vllm`'s `exes` stops a bare `python` from landing on the system PATH.
  - `index.html` loads Bootstrap from `cdn.jsdelivr.net`, so the **viewing browser** needs internet or the page renders unstyled.
  - Don't use `lmcache_frontend/run_mp_server_with_frontend.sh` as a model: that is fleet mode, which runs the app with `--no-http` (heartbeat-only) and reports to a central discovery service.
  - **0.5.6's JS calls three endpoint names the MP server no longer has.** Working tabs: Overview (basic), Metrics, Threads, Loglevel, Env. The Overview tab asks for `api/status` (server: `/status`) and falls back to a name/version card, so the L1 usage bar `renderMpOverview` draws never appears; Config asks for `conf` (server: `/config`) and Meta/Inference ask for `meta`/`inference_info`, which only exist when LMCache runs in-process inside vLLM. All three 404. Fixing it means patching `static/js/app.js`, which rebuilds lmcache from source.
  - Useful admin endpoints directly (`curl 127.0.0.1:8080/...`): `/status` (L1 bytes, L2 adapters, eviction policy, thread health), `/config`, `/metrics`, `/env`, `/threads`, `/periodic-threads`, `/quota`, `/lmc_version`. `GET /cache/objects?tier=l2` does **not** work with `fs_native` (`NativeConnectorL2Adapter` has no `list_l2_keys`).
- **Packaging.**
  - PyPI only has CUDA 13 LMCache wheels, so `nix/pyenv/pyproject.toml` sets `no-binary-package = ["lmcache"]` and `nix/package.nix` overrides it with `sourcePreference = "sdist"`.
  - The source build needs `grpcio-tools` to compile its protobuf files. It sits in the build-only `lmcache-build` dependency group, so it isn't installed at runtime.
  - The override builds against this set's torch 2.10, not the `torch==2.13` that LMCache's build-system pins.
  - `cuobjdump` on `cuda_ops.so` should show sm_70 images.
- **L2 eviction.** LMCache only evicts from L2 through its fleet coordinator, which we don't run. The `vllm-lmcache-l2-prune` timer (every minute) deletes the least recently accessed files once usage passes 90% of `l2SizeGb` (32 GB on c4130: above 28.8 GB), down to 80% (25.6 GB). This is safe because `fs_native` checks that each file exists on every lookup, so a pruned chunk is simply a miss.
- **Restarts.** L1 lives in the `vllm-lmcache` process, so restarting it empties L1 (L2 survives on disk). `vllm` requires `vllm-lmcache`, so restart `vllm` after it. Restarting only `vllm` keeps L1 warm.
- **RAM.** The L1 (default 64 GB, cut from 96 GB on 2026-10-29) is pinned and allocated in full at startup, despite the "lazy" allocator name. At 96 GB, Flint (whose vLLM peaks at ~27 GB of RAM while loading) ran the 125 GB box out of memory with no swap: the page cache starved, startup crawled for 14 min and the OOM killer hit LMCache. Qwen had left only ~16–18 GB free. Keep L1 + the active model's vLLM RAM peak + ~30 GB under 125 GB, and lower `services.lmcache-sm70.l1SizeGb` (`hosts/c4130/vllm/default.nix`) if the box needs more.
- **Checking hits.** `journalctl -u vllm | grep "External prefix cache hit rate"`. L2 contents: `du -sh /var/lib/lmcache/l2`.

## Flint
- **What it is.** `models.flint` serves Flint (RecursiveSI/flint, a 39.8B MoE with 2.5B active, NVFP4 W4A16) on the 1Cat-vLLM **source fork** (github.com/charlie-horse/vLLM), not the 1.5.1 wheel. The Qwen entries still use the wheel.
- **Files** (fork repo).
  - `nix/flint.nix` builds the fork's own tree (`nix/source.nix`) for sm_70 in the Nix sandbox and produces the checkpoint. The tree's store name is `1cat-vllm-flint-1.5.1.dev0+flint`, with no commit in it.
  - `nix/package.nix` returns `{ vllm, vllmFlint, lmcacheUi, flintConverter, flintCheckpoint, ... }`. `vllmFlint` is the stock venv with the fork tree first on `PYTHONPATH`, so the fork's runtime deps must stay equal to the wheel's (they are at the current pin).
- **Per-model fields** added to the module (`nix/module.nix`) for it:
  - `path`: serve a Nix store path instead of `downloads`. `vllm-model-fetch` then only checks the path exists.
  - `package`: which wrapped vllm runs (default: the stock wheel).
  - `env`: extra service environment.
  - `lmcache`: default true. When false, `--kv-transfer-config` is dropped and the `vllm-lmcache` unit is removed entirely, which frees the 64 GB pinned L1.
  - `maxNumSeqs`, and `asyncScheduling` (default false, which keeps `--no-async-scheduling`).
- **Weights are a build step.**
  - The GGUF (`RecursiveSI/flint-nvfp4-gguf`, pinned rev, full sha256) and the HF metadata files (`RecursiveSI/flint`, pinned rev) are fixed-output fetches.
  - A derivation converts them with the fork's `vllm.models.flint.convert_gguf` on CPU (~3.5 min, ~25 GB peak RAM). The output is byte-identical to the former hand-converted checkpoint (`~/flint/models/flint-nvfp4-modelopt`, deleted with `~/flint`).
  - The store holds both the GGUF and the checkpoint (~23 GB each). Only the current system generation roots the checkpoint. **Nothing roots the GGUF** (`/nix/store/jf1kpv19…-flint-nvfp4.gguf`): `~/archive/notes/flint-nix/gguf` is a plain symlink, not a registered GC root, so the next GC deletes the GGUF. That is fine. The GGUF is needed only to re-convert, and the checkpoint is fixed-output, so a missing checkpoint is fetched from r440's cache before anything converts.
- **Bumping the fork.**
  - Push to the fork (the flake follows its `latest` ref). In this repo, on a branch: `nix flake update vllm-fork` (or let the daily `update.yml` re-lock), wait for CI, merge. Then on c4130: `cd /etc/nixos && git pull`, `nixos-rebuild build --flake /etc/nixos#c4130`, start the RAM guard, `sudo nixos-rebuild switch --flake /etc/nixos#c4130`. There is no rev or hash to edit.
  - The deployed fork commit is the `vllm-fork` node in this repo's `flake.lock` at the commit c4130 last switched to (`git -C /etc/nixos log -1`); `main` may be ahead.
  - Only the serving tree (`vllmFlint`) rebuilds, which takes ~35 min at MAX_JOBS 16. A commit touching only `nix/` or `flake.*` doesn't change the tree's source, so it doesn't rebuild it.
  - The converter has its own pin, `converterFork` (`f66728d`) in the fork's `nix/flint.nix`. `nix/package.nix` wraps that tree as `flintConverter`, which only `flintCheckpoint` uses. Since fork `647bceb` the checkpoint is fixed-output (`checkpointHash = sha256-HyBUnISsTQXSKmmOft+/fNzrhFLwBJ6imMCa7YRAwoQ=`), so its path depends only on its name and that hash: `/nix/store/0qxvf6z208m6bff62acgwfg6ajhbinpp-flint-nvfp4-modelopt` (live since 2026-11-04). No fork, env, LMCache or nixpkgs change moves it. Before 647bceb it was input-addressed and moved with the env (`v3798n9…`, `9rw8az0d…`, all with the same content). Bump `converterFork`, and with it `checkpointHash`, only when the converter or the checkpoint format changes. That re-runs the conversion (~4 min) and adds a new 23 GB store path, so GC the old one.
  - Check that the `sm70_flash_attn_*` patch list in `nix/flint.nix` still matches the fork's `vllm_flash_attn.cmake`. CMake skips those patches when `VLLM_FLASH_ATTN_SRC_DIR` is set, so Nix applies them.
  - **Builds run on r440**, not here. Only with the local fallback (`--option max-jobs 4`, when r440 is down) does c4130 build itself; then stop LMCache first: with a Qwen model and LMCache running, only ~16–18 GB of RAM is free, while the conversion peaks at ~25 GB and the CUDA build runs 16 nvcc jobs.
- **Serving profile.** It mirrors the fork's `scripts/serve_flint_nvfp4_v100_pcie.sh`:
  - TP2, `--max-num-seqs 2`, 262K context, `gpuMemoryUtilization = 0.90`.
  - `--kernel-config.sm70_skinny_moe false`, glm47 tool and reasoning parsers, and default sampling of temperature 1.0, top-p 0.95, top-k 20.
  - Env: `CUDA_DEVICE_ORDER=PCI_BUS_ID`, `VLLM_SKIP_P2P_CHECK=0`.
  - **No `PYTORCH_ALLOC_CONF=expandable_segments:True`**, unlike the serve script. With expandable segments, PyTorch shares CUDA memory over IPC through `pidfd_getfd`. `kernel.yama.ptrace_scope = 1` denies that to the LMCache server, which is not vLLM's ancestor. The server then fails `register_kv_caches` with `pidfd_getfd: Operation not permitted`, vLLM times out after 300 s, and the unit restart-loops. Dropping it cost 0.25% of KV (978,974 vs 981,427 tokens) and no measurable decode speed.
- **LMCache: on (`lmcache = true`, `lmcacheChunkSize = 256`), verified 2026-10-29.** It stores (36 GB of L2 after a few 4K requests). It also loads with Flint's sliding-window + full-attention mix. A fixed 8K-token prompt, re-sent after restarting only `vllm` (L1 warm, GPU cache empty), took 0.31 s against 1.56 s for a cold 8K prompt, with identical output. Probe script: `~/archive/notes/flint-nix/lmc/probe.py <label> [seed]`.
  - At `5fc02fa`, the fork's factory (`vllm/distributed/kv_transfer/kv_connector/factory.py:105-107`) imports `kv_connector_module_path` before falling back to its registry (`:124`). Its HMA check (`:54-60`) passes because `LMCacheMPConnector` declares `SupportsHMA`. Re-check both on a fork bump.
  - The chunk size of 256 is a multiple of Flint's block size (16). `--separate-object-groups` stays on, since Flint has four KV-cache groups.
  - Budget ~2.2 GiB per GPU for the LMCache server: 0.90 utilization plus that is ~31 of 32 GB.
  - Flint keeps `asyncScheduling = true` (the profile it was tuned with), while the Qwen + LMCache entries run with `--no-async-scheduling`. If loads or stores misbehave, try `asyncScheduling = false` first.
- **Kernel switches** (on the fork branch with the single-token NVFP4 work): `VLLM_SM70_MODELOPT_NVFP4_GEMV=0` disables the dense M≤2 GEMV, and `VLLM_SM70_FLINT_MOE_QPN_DECODE=0` disables the routed-expert M≤2 decode path. Set either through the model's `env` to fall back to TurboMind.
- **`vllm.service` owns the GPUs.** The old `~/flint/gpu.lock` convention is retired, and `~/flint` itself is gone (its saved work is in `~/archive/flint-gpuopt-saved/`). The service never took that lock, so the lock can't protect it. Before any GPU job outside the service, including the hand harness in `~/vllm-hand`, kernel tests or benchmarks, check `systemctl is-active vllm` and stop the service first (with sudo, see "Stopping the service"). Then start it again when done. Both want both GPUs.

## Open WebUI
- **What it is.** Host file `hosts/c4130/vllm/open-webui.nix`, nixpkgs `services.open-webui` (0.11.3): a chat front-end for whatever `vllm.service` serves.
- **Access.** http://c4130:8082 over the tailnet (8080/8081 are LMCache's). Binds `0.0.0.0`; the port is opened only on `tailscale0`.
- **Backend.** `http://127.0.0.1:<services.vllm-sm70.port>/v1`; the model list comes from vLLM, so it follows `activeModel`. Ollama is off.
- **Auth.** `WEBUI_AUTH` on: the first signup becomes admin, later signups wait for the admin's approval.
- **Offline.** Telemetry and the update check are off. `OFFLINE_MODE` + `BYPASS_EMBEDDING_AND_RETRIEVAL` + `RAG_EMBEDDING_ENGINE=openai`, so no embedding, reranker or whisper model is downloaded or loaded. Attached documents go to the model whole, with no retrieval.
- **State.** `/var/lib/open-webui` (DynamicUser, so actually `/var/lib/private/open-webui`).
- **License.** nixpkgs marks it unfree (custom BSD-3 + branding), so it isn't in cache.nixos.org and builds from source; the host has `allowUnfree`.
- **Closure size.** open-webui 0.11.3 closure is 5.6 GiB (CPU torch 2.11, ffmpeg, opencv, pandoc, ...); it grew the system closure from 41.1 to 46.0 GiB. Its frontend (and nodejs 24) built from source on c4130 in ~25 min.

## Running a custom model
1. **Pick a checkpoint 1Cat can run on sm_70.**
   - Proven so far: block-FP8 (128×128) and NVFP4. 1Cat also lists AWQ/W4A16, compressed-tensors and GGUF.
   - BF16/FP16 full weights must fit in 2×32 GB with KV left over.
   - Grep 1Cat's `vllm/model_executor/layers/quantization/*sm70*` before choosing a new format.
2. **Add `services.vllm-sm70.models."<name>" = { ... };` in `hosts/c4130/vllm/default.nix`** in this repo, on a branch through CI (or in `builtinModels` in the fork's `nix/module.nix` for a built-in). Overriding one field of a built-in works the same way.
   - `downloads`: a list of `{ repo, revision, dir }`. The first entry is the served checkpoint; add a DFlash2 draft here if there is one. Always pin `revision` to a commit sha.
   - `args`: model-specific flags. Hybrid Qwen3.5/3.6/3.8 GDN models need `--language-model-only --mamba-cache-mode align`. Tool/reasoning parsers (`qwen3_coder`/`qwen3`) also go here.
   - Optional `maxModelLen` (default 262144) and `gpuMemoryUtilization` (default 0.88).
   - `lmcacheChunkSize`: must be a multiple of vLLM's block size for that model. If it's wrong, vLLM's startup error names the required value.
3. **Pre-download so `switch` doesn't block on the fetch.**
   - Run `nix shell nixpkgs#python3Packages.huggingface-hub nixpkgs#python3Packages.hf-xet -c hf download <repo> --revision <sha> --local-dir ~/qwen-staging/<dir>` (after `mkdir -p ~/qwen-staging`). Pass `HF_TOKEN` on stdin if the user provides one.
   - Then, with sudo: `mv` the dir into `/var/lib/vllm/models/`, `chown -R vllm:vllm`, and `touch <dir>/.complete-<sha>`.
4. **Set `activeModel` (in this repo, merged through CI), build, then switch.**
   - On c4130 as charlie: `cd /etc/nixos && git pull`, then `nixos-rebuild build --flake /etc/nixos#c4130`, and check the rendered `result/etc/systemd/system/vllm.service`.
   - Then `sudo nixos-rebuild switch --flake /etc/nixos#c4130`, plus `systemctl restart vllm` if it doesn't restart on its own. GC first if the root disk is tight (see "Deploying").
5. **Watch the start in the journal** with `journalctl _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value vllm)`.
   - Expect 3–6 minutes per start. The first start of a new model also JIT-compiles kernels.
   - Watch for "Application startup complete" or a Traceback.

## Gotchas learned the hard way
- **GPU memory budget.** The LMCache server takes ~2.2 GiB per GPU (CUDA context plus transfer staging during stores), outside vLLM's budget. Keep `gpuMemoryUtilization` at or below ~0.91, or long prefills OOM inside 1Cat's FP8 workspace.
- **KV must fit one full request.** Startup fails with "estimated maximum model length is N" if it doesn't. Lower `maxModelLen` or raise utilization (within the limit above).
- **Speculative decoding.** DFlash2 drafts (`incoai/*-DFlash2`) gave +70% decode on the 3.6-35B (111 vs 66 tok/s at 4K). They cost KV space.
- **Stopping the service.** `Restart=on-failure` brings `vllm` back after a crash or kill. Use `systemctl kill --signal=SIGKILL vllm` followed by `systemctl stop vllm`.
- **pgrep.** Over SSH, `pgrep -f <pattern>` matches its own `bash -c` command line; use `ps -ef | grep '[x]yz'` instead.
- **Thinking.** Flint always reasons: its chat template ends at `<|assistant|>` and has no `enable_thinking` switch, so `chat_template_kwargs.enable_thinking` does nothing. With the glm47 reasoning parser, the reasoning comes back in `reasoning_content`. The Qwen entries follow 1Cat's default (`enable_thinking` false); send `chat_template_kwargs.enable_thinking=true` there to get reasoning.
- **LMCache stops after 1 h if a vllm start sees no long prompt.** In LMCache 0.5.6 each vLLM worker starts pinging the cache server only on its first store (a prompt of at least one 256-token chunk). If none arrives within 1 h of a vllm start, the server reaps both GPU instances (`Reaped GPU instance …: silent for 3600.1s (pinged=False)` in `journalctl -u vllm-lmcache`). After that every store is rejected (`Rejecting STORE for unregistered GPU instance`) and nothing is reused until vllm restarts. A busy server is unaffected. Check with `curl -s 127.0.0.1:8080/status`: `registered_gpu_ids` should list 2 ids. Workaround: restart only `vllm` and send one ≥256-token prompt within the hour. The fix (start the heartbeat at registration) is in the new flake, charlie-horse/vllm-sm70 PR #10; it is not in the fork.
- **CacheBlend** doesn't apply to hybrid GDN models; LMCache only does prefix reuse there.

## State as of 2026-11-04
- **c4130 runs flake `8a54e1f` / fork `cf9492a`**, system-42 (`/nix/store/shjjhcm4biv99i3zswbmv1j3jmbv11rw-nixos-system-c4130-26.05.20261102.7dcdd87`), switched 2026-11-04 16:06:40 EST. The outage was 3 min 26 s (vllm stopped at 16:06:28, ready at 16:09:54).
  - Flint checkpoint: the fixed-output `0qxvf6z2…`, fetched from r440's cache, so nothing re-converted. The old `9rw8az0d…` is garbage.
  - LMCache L2 is now 32 GB live (`max_capacity_gb 32`; it was 100 until this switch).
  - Bench (Bea, single stream): 4K 176.6 / 176.6 tok/s default / greedy (ITL 5.58 ms, TTFT 0.72 s); 32K 163.9 / 162.7 (ITL 6.21 ms, TTFT 10.5 s). Math 10/10, code 5/5, needle 32K 3/3. That is the same as e66530b (176.8 / 178.2 and 162.8 / 162.7).
  - LMCache was registered and storing after the switch (4948 objects, ~31.8 GB L1 at 16:14). Mind the 1-h reaper caveat under "Gotchas".
- The successor flake is charlie-horse/vllm-sm70: upstream vLLM v0.33 + an sm_70 patch series, with the same `services.vllm-sm70` / `services.lmcache-sm70` options. It is not deployed (see "After cutover").

## After cutover (charlie-horse/vllm-sm70)
Applies once c4130 has switched to a flake commit whose `vllm-fork` input is `github:charlie-horse/vllm-sm70` (main). Until then the sections above describe what runs.
- **Input.** Same name, `vllm-fork`, so `hosts/c4130/vllm/default.nix` is unchanged; it follows `main` of vllm-sm70 (Nix code under `nix/`, docs in its `nix/README.md`). Its input `vllm-legacy` (the old fork at `cf9492a`, with its own locked nixpkgs) is used only for the Flint checkpoint recipe; the checkpoint stays the fixed-output `/nix/store/0qxvf6z208m6bff62acgwfg6ajhbinpp-flint-nvfp4-modelopt`, so nothing re-converts.
- **Second nixpkgs in the lock.** `vllm-legacy` brings its own nixpkgs (`c3eea5b`) and a second pyproject-build-systems (plus pyproject-nix/uv2nix) into `flake.lock`. They are only evaluated: nothing is built from them while the checkpoint path is in the store (rooted by the current generation, or substitutable from r440). Their sources are eval-time inputs, not part of any system closure, so a GC may delete them and the next eval re-fetches them.
- **Dropped fork-only flags** (`TODO(sm70-attn)` / `TODO(sm70-moe)` in vllm-sm70's `nix/module.nix`): `--kernel-config.sm70_skinny_moe false` (Flint) and `--attention-backend FLASH_ATTN_V100` (Qwen 3.8-27B and the DFlash draft). Upstream v0.33 rejects them until the patch series adds them, so vLLM falls back to TRITON_ATTN.
- **Kill switches.** Only `VLLM_SM70_<THING>=0` does anything (turns that sm_70 feature off); env vars can't turn features on, and other `VLLM_SM70_*` variables from the fork are ignored. Set one per model with `models.<name>.env`. Defaults/tuning go through `--additional-config '{"sm70":{...}}'`. `VLLM_PLUGINS` set to a list without `sm70` (e.g. `VLLM_PLUGINS=`) disables the sm70 plugin and runs stock vLLM.

  | Variable (Flint, kept from the fork) |
  |---|
  | `VLLM_SM70_MODELOPT_NVFP4_GEMV` |
  | `VLLM_SM70_FLINT_MOE_QPN_DECODE` |
  | `VLLM_SM70_FLINT_QK_ROPE_KV` |
  | `VLLM_SM70_FLINT_FUSED_ROUTER` |
  | `VLLM_SM70_FLINT_SAMPLER` |
  | `VLLM_SM70_FLINT_ATTN_FUSED_DECODE` |
  | `VLLM_SM70_FLINT_AR_RMSNORM` |

  New on this stack: `VLLM_SM70_FP8_MOE_DECODE`, `_FP8_QPN8` (new meaning, not the fork's TP4 one), `_QUANT`, `_FP8_TURBOMIND`, `_DFLASH2_EMULATION`, `_DFLASH2_VERIFIER`, `_SHARED_MOE_OVERLAP`.
- **LMCache heartbeat.** vllm-sm70 carries the heartbeat-from-registration patch (`nix/patches/lmcache/`), which removes the 1-h reaper gotcha once its LMCache build is in place. Re-check `registered_gpu_ids` after the first switch anyway.

## State as of 2026-10-29
- 2026-10-31: Nix code moved into the fork as a flake (input `vllm-fork`).
- **Flint is live on `vllm.service`** (switched 2026-10-30 00:45 EDT), with LMCache on (L1 64 GB, L2 180 GB then; 32 GB now), from fork `2eb8f3b` (main, with the GPU decode fusions; converter pinned at `f66728d`).
  - Nix-built service, 4K single stream: 173.8 tok/s default / 175.8 greedy, ITL 5.62 ms, TTFT 0.70 s. The dev tree measured 179.3 / 179.5 at ITL 5.59 ms; the difference is run spread.
  - Previous production pin `5fc02fa`: 117.8 / 123.0 tok/s.
  - LMCache re-checked: the stored 8K prompt took 0.27 s after a vllm-only restart, against 1.59 s cold.
  - New default-on kill switches, to set in the model's `env` if one misbehaves: `VLLM_SM70_FLINT_FUSED_ROUTER`, `VLLM_SM70_FLINT_ATTN_FUSED_DECODE`, `VLLM_SM70_FLINT_QK_ROPE_KV`, `VLLM_SM70_FLINT_SAMPLER` and `VLLM_SM70_FLINT_AR_RMSNORM` (`0` = off). `VLLM_SM70_FLINT_MOE_PERSISTENT` is off by default.
  - main has moved past the pin: `7211bb9` (config-owner fix, no behaviour change). Pick it up on the next fork bump.
  - Bump procedure: see "Bumping the fork" (re-lock in this repo on a branch, CI, merge, then on c4130: `git pull`, build, RAM guard, switch).
  - Smoke test passed (17×23 → 391).
  - The hand-run `~/flint/serve.sh`, `~/flint/convert.sh` and `~/flint/dl.sh` were removed (copies in `~/archive/notes/flint-nix/retired/`): `vllm.service` serves Flint and `nix/flint.nix` fetches the HF metadata and converts the weights. `~/flint` has since been deleted.
- **What went wrong on the way, all fixed in config:**
  - The first switch (12:53) ran the box out of RAM: LMCache's 96 GB L1 plus Flint's ~27 GB load peak, with no swap. SSH and ping stopped until the OOM killer hit LMCache at 13:06. The L1 default is now 64 GB.
  - The second start restart-looped on the expandable-segments IPC issue above.
  - Backups of each step are in `~/archive/notes/flint-nix/` (the old `~/flint-nix`): `default.nix.pre-l1-64`, `default.nix.pre-noexpand`, `CLAUDE.md.pre-l1-64`, `SWITCH-STEPS.md`, plus switch logs.
  - The guard script that stops vllm and LMCache if MemAvailable drops under 6 GB is `~/archive/notes/flint-nix/ramguard.sh` (`sudo systemd-run --unit=… --collect ~/archive/notes/flint-nix/ramguard.sh`, runs ~25 min). Use it around risky starts.
- Backups of `/etc/nixos`, all in `~/archive/nixos-backups/` on c4130: `nixos-backup-20261028-1431` (pre-vLLM), `nixos-backup-20261029-0832-pre-flint`, `nixos-backup-20261029-1151-pre-lmcache-ui`, `nixos-backup-20261031-1033-pre-flake`, `nixos-backup-20261103-pre-flake-checkout`.
- The Qwen3.6 `lmcacheChunkSize = 1056` is still unverified (its LMCache test never finished). Before the Flint work, the normal default was `qwen3.8-27b`. Qwen3.8 was verified with LMCache at L1 96 GB; at 64 GB, re-check hits before relying on it.
- **Qwen3.8-27B** (FP8 + DFlash2, 150K context, 0.91 utilization, chunk size 8192) is verified with LMCache:
  - Cold 100K-token prompt: 66 s TTFT. From L1: 1.8 s. From L2: 9.1 s. Answers were identical across all three.
  - 4K decode: ~80–128 tok/s.
- **The dashboard (`vllm-lmcache-ui`) runs under systemd since the 13:33 switch.** `/` returns 200 and `/api/nodes` lists the LMCache server; the cache figures under real traffic aren't checked yet. It was first validated out of band, before any switch:
  - `nix eval` of the rendered `ExecStart`s and `nix build --no-link` of the toplevel both pass (use `nix build`, not `nixos-rebuild build`, which writes `./result` and clobbers `~/result`).
  - A standalone pair was run as charlie with reduced tiers: `lmcache server … --port 5556 --http-port 8086 --chunk-size 256 --l1-size-gb 2` with a 2 GB L2 under `~/lmcache-uitest`, plus the dashboard on 127.0.0.1:8087. Clean startup, no errors in either log, ~3.5 GB RSS total and 316 MiB on one GPU. `/`, `/static/*`, `/api/nodes`, both proxy hops and the aggregated `/metrics` all 200; an unregistered proxy target correctly 403s. Cache counters read zero because no vLLM was attached. Both processes, the test directory, and the temporary `tailscale serve --http=8081` bridge used to view it have all been removed — no out-of-Nix state is left.
  - On switch both units come up: `vllm-lmcache-ui` is `wantedBy = multi-user.target` and `requires` `vllm-lmcache`, which (like `vllm.service`) pulls the cache server in. Stopping `vllm-lmcache` therefore also stops the dashboard.
  - Remaining unverified: the units running as `vllm` with `StateDirectory`, and the cache figures under real traffic.
- If the dashboard ever needs to be reachable before a switch, `sudo tailscale serve --bg --http=8081 http://127.0.0.1:<port>` bridges it without a firewall edit; it matches on the Host header, so use `http://c4130:8081/` and not the tailnet IP. It is persistent root state outside Nix — undo with `sudo tailscale serve --http=8081 off` before the real unit claims 8081.

## Remote builder and cache (r440)
- `hosts/c4130/builder.nix` here; `hosts/r440/builder.nix` + `hosts/r440/firewall.nix` for r440. Direct 2x25G link: LACP `bond0`, MTU 9000, c4130 10.25.0.1/30, r440 10.25.0.2/30 (cables crossed: r440 ens3f0np0 ↔ c4130 enp8s0f1np1, ens3f1np1 ↔ enp8s0f0np0).
- c4130 builds nothing itself (`max-jobs = 0`): every derivation goes to `ssh-ng://nixremote@10.25.0.2` (key `/root/.ssh/nixremote`). If r440 is down, build with `--option max-jobs 4` and expect the RAM use (vLLM + LMCache hold ~90 GB).
- r440's harmonia (`http://10.25.0.2:5000`, priority 30) is the first substituter; its signing key stays in r440's `/var/lib/secrets/harmonia.secret`.
- Concurrency: `builderMaxJobs` at the top of r440's builder.nix and `maxJobs` in this host's builder.nix must match. It is 2 builds × 8 cores (`nix.settings.cores`), so at most 16 nvcc on r440: on 2026-11-04 two CUDA trees at 16 nvcc each exhausted r440's 46 GiB and hung it. Both the flint tree and (since fork 23ea1b6) LMCache run min(NIX_BUILD_CORES, 16) nvcc jobs. Keep max-jobs × cores at 16.
- r440's `memory.nix` adds 25% zram swap (kubelet runs with `failSwapOn: false`, pods `NoSwap`) and caps `nix-daemon.service` (all builds, including this host's) at `MemoryHigh=32G` / `MemoryMax=36G` / `MemorySwapMax=4G`, `OOMScoreAdjust=500`. A build that hits the cap fails with an OOM kill on r440 instead of hanging the box; retry it.
- c4130 opens TCP 8000 on bond0 to 10.25.0.2 only (vLLM API for r440 workloads).

## Files on the host (c4130, `~charlie`)
- `~/archive/scripts/`: check and test scripts (see "Stack").
- `~/archive/notes/flint-nix/`: the old `~/flint-nix` (RAM guard, `SWITCH-STEPS.md`, `retired/`, `gguf`, step backups, logs, `lmc/probe.py`).
- `~/archive/flint-gpuopt-saved/`: work saved from the deleted `~/flint`.
- `~/archive/results/kvtier_results.json`, `~/archive/builds/flint-k8s-build`.
- `~/archive/nixos-backups/`: old `/etc/nixos` copies (listed under "State").
- `~/vllm-hand` stays in the home directory: it is the active hand harness.
