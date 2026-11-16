# c4130 vLLM / LMCache

Docs: [docs/hosts/c4130-vllm.md](../../../docs/hosts/c4130-vllm.md) (stack, LMCache, Flint, kill switches, custom models), [docs/hosts/c4130.md](../../../docs/hosts/c4130.md) (hardware, deploy, files on the host).

This directory only sets host values; the modules come from flake input `vllm-fork` (vllm-sm70).

Rules:
- Every change (model entry, `vllm-fork` re-lock) goes through this repo: branch, CI, merge. Never edit `/etc/nixos` or run `nix flake update` on the host.
- GC old generations before every c4130 switch.
- CUDA 13 can't target sm_70 (use CUDA 12.x); no bf16, run `--dtype half`. Keep `gpuMemoryUtilization` <= ~0.91 (LMCache takes ~2.2 GiB per GPU).
- Flint's reasoning is in `message.reasoning` (`reasoning_content` is empty). `models.<name>.args` replaces the built-in list.
