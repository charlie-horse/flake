# c4130 vLLM inference host

c4130 is one of the three NixOS 26.05 servers (c4130, r440, m2mini) that run the neurosis cluster. Its config is `hosts/c4130/` in this repo. On every server, `/etc/nixos` is a git checkout of `main` (owned charlie:root, mode 0755) and the only checkout; `~/src/flake` is gone. The vLLM setup is `hosts/c4130/vllm/`, which consumes the vLLM fork's flake (input `vllm-fork`). **`hosts/c4130/vllm/CLAUDE.md` is the canonical vLLM/LMCache doc**; the cluster runbook is `docs/cluster.md` (history: `docs/history/`), the PKI is in `docs/pki.md`.

## Access from a cloud session
- Only SSH to the hosts when the user has allowed it for the task.
- Tailscale isn't preinstalled. Download the static `tailscale_<ver>_amd64.tgz` from pkgs.tailscale.com (piping the install script into `sh` gets blocked), then run `tailscaled --tun=userspace-networking --statedir=/var/lib/tailscale --socket=/var/run/tailscale/tailscaled.sock` in the background and `tailscale up --authkey="$TAIL_AUTH_KEY" --hostname=flake-cloud --accept-routes`. `TAIL_AUTH_KEY` is in the environment. The node can get logged out after container restarts; if `status` shows no peers, run `up` again.
- SSH goes through Tailscale SSH as `charlie`: `ssh -o ProxyCommand="tailscale --socket=… nc %h %p" charlie@c4130` (install `openssh-client` with apt).
- `sudo`: since the sops-nix cutover (`modules/system/admin.nix`), `users.mutableUsers = false`, root is locked and **charlie has no password and no sudo**; the wheel account is `admin` (password in sops, `secrets/common.yaml` key `admin-password`; read it with `sops -d --extract '["admin-password"]' secrets/common.yaml` and the YubiKey). The tailnet SSH policy currently only permits `charlie`, so from a cloud session SSH as charlie and become admin with `su admin` (needs a pty: `script -qec 'su admin -c …'`), or ask the user to add `admin` to the Tailscale SSH policy. Ask the user for admin's password and pass it on stdin, never on a command line. Hosts not yet switched to the sops generation still use charlie's sudo password. Secrets never go in git or on a command line. Every secret and where it lives: `docs/cluster.md`, "Secrets (all of them)"; add a row there for any new one.
- `/etc/nixos` is writable by charlie, so `git pull` and building need no sudo (still true after the cutover); `nixos-rebuild switch` and `journalctl -u vllm` do.
- etcd and the k8s apiserver also run on this box (3-member etcd with r440 and m2mini). Switch one host at a time and run the etcd health check from `docs/cluster.md` after each. `switch` exiting with status 4 means a unit failed; read `systemctl --failed`. Leave etcd alone unless the user asks.
- The cluster PKI (CA keys) lives only on r440 (`~/.local/share/cluster-pki/neurosis`); never copy it elsewhere or into git.

## Deploying
- Change or re-lock in this repo on a branch → CI → merge. Then on the host: `cd /etc/nixos && git pull && sudo nixos-rebuild switch --flake /etc/nixos#<host>` (m2mini adds `--override-input m2mini-vendorfw path:/boot/vendorfw`).
- Never run `nix flake update` or edit files inside `/etc/nixos` on a host.
- **GC old generations before any c4130 switch** (Charlie's rule): `sudo nix-env -p /nix/var/nix/profiles/system --delete-generations +2 && sudo nix-collect-garbage`. After a switch that replaces the Flint checkpoint, GC the old 23 GB path. What each host runs: `nix-store -qd /run/current-system` and `git -C /etc/nixos log -1` (don't record it here; it goes stale). Status 2026-11-12: c4130 root disk at 60%.
- Switch c4130 outside the GPU window (vLLM is stopped 22:00–05:55 EST by `gpu-window-*` timers; a switch inside it starts vLLM again).
- Builds happen on r440 only: c4130 has `max-jobs = 0`; r440 builds 2 jobs × 8 cores, with nix-daemon capped at 36G and zram swap.

## Hardware
- 2× Tesla V100-PCIe-32GB, both sm_70, on the same PCIe switch with no NVLink. Driver 580, the last driver branch for Volta.
- 48 threads, 125 GB RAM, and SATA SSD RAID1.
- **CUDA 13 can't target sm_70.** Anything that compiles or ships GPU kernels must use CUDA 12.x (the fork stack uses 12.8; after cutover vllm-sm70 uses 12.6, torch 2.14.0+cu126). No bf16 support, so run everything as `--dtype half`.

## Stack summary (details in `hosts/c4130/vllm/CLAUDE.md`)
- The Nix code (Python env, wrappers, `vllm`/LMCache modules, Flint build) is in the fork repo (github.com/charlie-horse/vLLM, `nix/`). `hosts/c4130/vllm/default.nix` only sets host values under `services.vllm-sm70` and `services.lmcache-sm70`.
- Cut over on 2026-11-12 (c4130 runs `vllm-sm70-service-0.33.0`): input `vllm-fork` points at github.com/charlie-horse/vllm-sm70, branch `latest` (gated release branch; same name and options, Flint checkpoint path unchanged). `FLASH_ATTN_V100` and `--kernel-config.sm70_skinny_moe` are dropped there for now (TODO(sm70-attn)/TODO(sm70-moe)), so vLLM uses TRITON_ATTN. Kill switches: `hosts/c4130/vllm/CLAUDE.md`, "After cutover".
- One model runs at a time, chosen by `services.vllm-sm70.activeModel`. vLLM listens on port 8000 (`eno1` and `tailscale0`, no API key; the user relies on network policy).
- LMCache: L1 64 GB of pinned RAM, allocated in full at startup. L2 in `/var/lib/lmcache/l2`, capped at 32 GB (`services.lmcache-sm70.l2SizeGb`, set in `hosts/c4130/vllm/default.nix`); the pruner trims it to 80% once it passes 90%.
- Flint's weights are a Nix store path: the fixed-output checkpoint `/nix/store/0qxvf6z208m6bff62acgwfg6ajhbinpp-flint-nvfp4-modelopt`. HF-downloaded weights (the Qwen entries) live in `/var/lib/vllm/models`, owned by `vllm`. That directory has been empty since 2026-11-04 (the Qwen weights and DFlash2 drafts were deleted), so switching to a Qwen model re-downloads ~70 GB first.
- Check scripts are in `~/archive/scripts` on c4130 (`verify_vllm.py`, `bench_vllm.py`, `kvtier_test.py`, …). `bench_vllm.py` is broken for Flint: it counts only `content` tokens, and Flint always reasons first.
- Old `/etc/nixos` backups are in `~/archive/nixos-backups/` on each host.

## Gotchas learned the hard way
- **GPU memory budget.** The LMCache server takes ~2.2 GiB per GPU (CUDA context plus transfer staging during stores), outside vLLM's budget. Keep `gpuMemoryUtilization` at or below ~0.91, or long prefills OOM inside 1Cat's FP8 workspace.
- **KV must fit one full request.** Startup fails with "estimated maximum model length is N" if it doesn't. Lower `maxModelLen` or raise utilization (within the limit above).
- **Speculative decoding.** DFlash2 drafts (`incoai/*-DFlash2`) gave +70% decode on the 3.6-35B (111 vs 66 tok/s at 4K). They cost KV space.
- **Stopping the service.** `Restart=on-failure` brings `vllm` back after a crash or kill. Use `systemctl kill --signal=SIGKILL vllm` followed by `systemctl stop vllm`.
- **pgrep.** Over SSH, `pgrep -f <pattern>` matches its own `bash -c` command line; use `ps -ef | grep '[x]yz'` instead.
- **Thinking.** Flint always reasons: its chat template ends at `<|assistant|>` and has no `enable_thinking` switch, so `chat_template_kwargs.enable_thinking` does nothing. Since the vllm-sm70 cutover (2026-11-12, vLLM 0.33, parser plugin `vllm_sm70.reasoning`, parser `glm47_sm70`) the reasoning comes back in **`message.reasoning`** (streaming: `delta.reasoning`); `reasoning_content` is empty. Clients must read `reasoning` (or fall back to it): `~/archive/scripts/verify_vllm.py` already accepts both; Open WebUI (v0.12.2) is expected to handle `reasoning` but was not re-checked. The Qwen entries follow 1Cat's default (`enable_thinking` false); send `chat_template_kwargs.enable_thinking=true` there to get reasoning.
- **LMCache stops after 1 h if a vllm start sees no long prompt.** In LMCache 0.5.6 each vLLM worker starts pinging the cache server only on its first store (a prompt of at least one 256-token chunk). If none arrives within 1 h of a vllm start, the server reaps both GPU instances (`Reaped GPU instance …: silent for 3600.1s (pinged=False)` in `journalctl -u vllm-lmcache`). After that every store is rejected (`Rejecting STORE for unregistered GPU instance`) and nothing is reused until vllm restarts. A busy server is unaffected. Check with `curl -s 127.0.0.1:8080/status`: `registered_gpu_ids` should list 2 ids. Workaround: restart only `vllm` and send one ≥256-token prompt within the hour. The fix (start the heartbeat at registration) is in the new flake, charlie-horse/vllm-sm70 PR #10; it is not in the fork.
- **CacheBlend** doesn't apply to hybrid GDN models; LMCache only does prefix reuse there.
