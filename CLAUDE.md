# c4130 vLLM inference host

c4130 is a separate NixOS 26.05 machine. Its config is NOT in this repo: it lives in its own flake at `/etc/nixos` on the box (not under git; pre-vLLM backup in `/home/charlie/nixos-backup-20261028-1431`). The vLLM setup is the `./vllm` module there.

## Access from a cloud session
- Tailscale isn't preinstalled. Download the static `tailscale_<ver>_amd64.tgz` from pkgs.tailscale.com (piping the install script into `sh` gets blocked), then run `tailscaled --tun=userspace-networking --statedir=/var/lib/tailscale --socket=/var/run/tailscale/tailscaled.sock` in the background and `tailscale up --authkey="$TAIL_AUTH_KEY" --hostname=flake-cloud --accept-routes`. `TAIL_AUTH_KEY` is in the environment. The node can get logged out after container restarts; if `status` shows no peers, run `up` again.
- SSH goes through Tailscale SSH as `charlie`: `ssh -o ProxyCommand="tailscale --socket=… nc %h %p" charlie@c4130` (install `openssh-client` with apt).
- `sudo` needs charlie's password. Ask the user for it, and pass it on stdin (`sudo -S`), never on a command line. `/etc/nixos` is writable by charlie, so building needs no sudo; `nixos-rebuild switch` and `journalctl -u vllm` do.
- etcd and the k8s apiserver also run on this box. etcd failing to reach quorum (and `switch` exiting with status 4 because of it) predates the vLLM work. Leave it alone unless the user asks.

## Hardware
- 2× Tesla V100-PCIe-32GB, both sm_70, on the same PCIe switch with no NVLink. Driver 580, the last driver branch for Volta.
- 48 threads, 125 GB RAM, and SATA SSD RAID1 with ~226 GB free.
- **CUDA 13 can't target sm_70.** Anything that compiles or ships GPU kernels must use CUDA 12.x (the stack uses 12.8). No bf16 support, so run everything as `--dtype half`.

## Stack (`/etc/nixos/vllm/`)
- `pyenv/pyproject.toml` + `uv.lock`: the Python environment, built by Nix through uv2nix.
  - 1Cat-vLLM 1.5.1 (a Volta fork of vLLM) comes from its SM70 release wheel.
  - torch 2.10.0+cu128 (includes sm_70).
  - LMCache 0.5.6 is built from its PyPI sdist with `LMCACHE_CUDA_MAJOR=12`. Its deps are declared statically in `[[tool.uv.dependency-metadata]]`, with numpy/prometheus/otel upper bounds relaxed.
  - Re-lock with `uv lock --python 3.12` (uv isn't on c4130; lock elsewhere and copy the files over).
- `package.nix`: builds the env and wraps `vllm`, `hf` and `lmcache` with the runtime setup:
  - `LD_LIBRARY_PATH` covering the driver libs, the nvidia-* wheel libs, `tvm_ffi`, and `z3`.
  - `CUDA_HOME` pointing at the CUDA 12.8 toolkit, plus `NVCC_PREPEND_FLAGS=-I<toolkit>/include`, which the JIT needs.
  - It also holds the LMCache source-build override.
- `default.nix`:
  - A `models` table, with `c4130.vllm.activeModel` selecting which model runs. Only one fits on the GPUs at a time.
  - Systemd units: `vllm-model-fetch`, `vllm-lmcache` (L1 = 96 GB pinned RAM, allocated in full at startup; L2 = `/var/lib/lmcache/l2` capped at 180 GB by the `vllm-lmcache-l2-prune` timer), and `vllm`.
  - Port 8000 is open on `eno1` (LAN `10.0.0.95`) and `tailscale0`, with no API key (the user relies on network policy instead).
- Weights live in `/var/lib/vllm/models`, owned by `vllm`.
- Check scripts are in `/home/charlie`: `verify_vllm.py` (models / tool calls / recall), `bench_vllm.py` (TTFT and decode tok/s; set `MODEL=`), and `kvtier_test.py` (cold vs L1 vs L2).

## LMCache details
- **Connector.** vLLM loads LMCache's own connector, not the one bundled in 1Cat, which targets an older LMCache API (`lmcache.v1.multiprocess.mq`/`protocol` no longer exist). In `--kv-transfer-config`:
  - `kv_connector: LMCacheMPConnector`
  - `kv_connector_module_path: lmcache.integration.vllm.lmcache_mp_connector` (1Cat's factory checks the module path before its own registry)
  - `kv_load_failure_policy: recompute`, so a failed or missing chunk is recomputed instead of erroring
  - `lmcache.mp.host: tcp://127.0.0.1`, `lmcache.mp.port: 5555`
- **Server flags** (`vllm-lmcache`): `lmcache server --host 127.0.0.1 --port 5555 --http-host 127.0.0.1 --separate-object-groups --chunk-size <model.lmcacheChunkSize> --l1-size-gb 96 --eviction-policy LRU --l2-adapter '{"type":"fs_native",...}'`.
  - `--separate-object-groups` is required for hybrid GDN models.
  - Everything binds to localhost only.
  - Tier sizes live in the `kvTiers` block at the top of `default.nix`.
- **Packaging.**
  - PyPI only has CUDA 13 LMCache wheels, so `pyproject.toml` sets `no-binary-package = ["lmcache"]` and `package.nix` overrides it with `sourcePreference = "sdist"`.
  - The source build needs `grpcio-tools` to compile its protobuf files. It sits in the build-only `lmcache-build` dependency group, so it isn't installed at runtime.
  - The override builds against this set's torch 2.10, not the `torch==2.13` that LMCache's build-system pins.
  - `cuobjdump` on `cuda_ops.so` should show sm_70 images.
- **L2 eviction.** LMCache only evicts from L2 through its fleet coordinator, which we don't run. The `vllm-lmcache-l2-prune` timer (every minute) deletes the least recently accessed files once usage passes 90% of 180 GB, down to 80%. This is safe because `fs_native` checks that each file exists on every lookup, so a pruned chunk is simply a miss.
- **Restarts.** L1 lives in the `vllm-lmcache` process, so restarting it empties L1 (L2 survives on disk). `vllm` requires `vllm-lmcache`, so restart `vllm` after it. Restarting only `vllm` keeps L1 warm.
- **RAM.** The 96 GB L1 is pinned and allocated in full at startup, despite the "lazy" allocator name. With vLLM running, only ~16–18 GB of RAM stays available. Lower `kvTiers.l1SizeGb` if the box needs more.
- **Checking hits.** `journalctl -u vllm | grep "External prefix cache hit rate"`. L2 contents: `du -sh /var/lib/lmcache/l2`.

## Running a custom model
1. **Pick a checkpoint 1Cat can run on sm_70.**
   - Proven so far: block-FP8 (128×128) and NVFP4. 1Cat also lists AWQ/W4A16, compressed-tensors and GGUF.
   - BF16/FP16 full weights must fit in 2×32 GB with KV left over.
   - Grep 1Cat's `vllm/model_executor/layers/quantization/*sm70*` before choosing a new format.
2. **Add an entry to `models` in `default.nix`.**
   - `downloads`: a list of `{ repo, revision, dir }`. The first entry is the served checkpoint; add a DFlash2 draft here if there is one. Always pin `revision` to a commit sha.
   - `args`: model-specific flags. Hybrid Qwen3.5/3.6/3.8 GDN models need `--language-model-only --mamba-cache-mode align`. Tool/reasoning parsers (`qwen3_coder`/`qwen3`) also go here.
   - Optional `maxModelLen` (default 262144) and `gpuMemoryUtilization` (default 0.88).
   - `lmcacheChunkSize`: must be a multiple of vLLM's block size for that model. If it's wrong, vLLM's startup error names the required value.
3. **Pre-download so `switch` doesn't block on the fetch.**
   - Run `nix shell nixpkgs#python3Packages.huggingface-hub nixpkgs#python3Packages.hf-xet -c hf download <repo> --revision <sha> --local-dir /home/charlie/qwen-staging/<dir>`. Pass `HF_TOKEN` on stdin if the user provides one.
   - Then, with sudo: `mv` the dir into `/var/lib/vllm/models/`, `chown -R vllm:vllm`, and `touch <dir>/.complete-<sha>`.
4. **Set `activeModel`, build, then switch.**
   - Build as charlie: `nixos-rebuild build --flake /etc/nixos#c4130`, and check the rendered `result/etc/systemd/system/vllm.service`.
   - Then `sudo nixos-rebuild switch`, plus `systemctl restart vllm` if it doesn't restart on its own.
5. **Watch the start in the journal** with `journalctl _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value vllm)`.
   - Expect 3–6 minutes per start. The first start of a new model also JIT-compiles kernels.
   - Watch for "Application startup complete" or a Traceback.

## Gotchas learned the hard way
- **GPU memory budget.** The LMCache server takes ~2.2 GiB per GPU (CUDA context plus transfer staging during stores), outside vLLM's budget. Keep `gpuMemoryUtilization` at or below ~0.91, or long prefills OOM inside 1Cat's FP8 workspace.
- **KV must fit one full request.** Startup fails with "estimated maximum model length is N" if it doesn't. Lower `maxModelLen` or raise utilization (within the limit above).
- **Speculative decoding.** DFlash2 drafts (`incoai/*-DFlash2`) gave +70% decode on the 3.6-35B (111 vs 66 tok/s at 4K). They cost KV space.
- **Stopping the service.** `Restart=on-failure` brings `vllm` back after a crash or kill. Use `systemctl kill --signal=SIGKILL vllm` followed by `systemctl stop vllm`.
- **pgrep.** Over SSH, `pgrep -f <pattern>` matches its own `bash -c` command line; use `ps -ef | grep '[x]yz'` instead.
- **Thinking default.** 1Cat defaults `enable_thinking` to false. The user currently keeps that default, so requests must send `chat_template_kwargs.enable_thinking=true` to get reasoning.
- **CacheBlend** doesn't apply to hybrid GDN models; LMCache only does prefix reuse there.

## State as of 2026-10-29
- `vllm` and `vllm-lmcache` were stopped (SIGKILL + stop) at the user's request. Both GPUs are free.
- `activeModel` in `/etc/nixos/vllm/default.nix` was temporarily set to `qwen3.6-35b-a3b` for an LMCache test that never finished; its `lmcacheChunkSize = 1056` is unverified. The normal default is `qwen3.8-27b`.
- **Qwen3.8-27B** (FP8 + DFlash2, 150K context, 0.91 utilization, chunk size 8192) is verified with LMCache:
  - Cold 100K-token prompt: 66 s TTFT. From L1: 1.8 s. From L2: 9.1 s. Answers were identical across all three.
  - 4K decode: ~80–128 tok/s.
