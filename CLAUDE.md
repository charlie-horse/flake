# c4130 vLLM inference host

c4130 is one of the three NixOS 26.05 servers (c4130, r440, m2mini) that run the solaris cluster. Its config is `hosts/c4130/` in this repo. On every server, `/etc/nixos` is a git checkout of `main` (owned charlie:root, mode 0755) and the only checkout; `~/src/flake` is gone. The vLLM setup is `hosts/c4130/vllm/`, which consumes the vLLM fork's flake (input `vllm-fork`). **`hosts/c4130/vllm/CLAUDE.md` is the canonical vLLM/LMCache doc**; the cluster runbook is `docs/cluster-handoff.md`, the PKI is in `docs/pki.md`.

## Access from a cloud session
- Only SSH to the hosts when the user has allowed it for the task.
- Tailscale isn't preinstalled. Download the static `tailscale_<ver>_amd64.tgz` from pkgs.tailscale.com (piping the install script into `sh` gets blocked), then run `tailscaled --tun=userspace-networking --statedir=/var/lib/tailscale --socket=/var/run/tailscale/tailscaled.sock` in the background and `tailscale up --authkey="$TAIL_AUTH_KEY" --hostname=flake-cloud --accept-routes`. `TAIL_AUTH_KEY` is in the environment. The node can get logged out after container restarts; if `status` shows no peers, run `up` again.
- SSH goes through Tailscale SSH as `charlie`: `ssh -o ProxyCommand="tailscale --socket=… nc %h %p" charlie@c4130` (install `openssh-client` with apt).
- `sudo` needs charlie's password. Ask the user for it, and pass it on stdin (`sudo -S`), never on a command line. Secrets never go in git or on a command line.
- `/etc/nixos` is writable by charlie, so `git pull` and building need no sudo; `nixos-rebuild switch` and `journalctl -u vllm` do.
- etcd and the k8s apiserver also run on this box (3-member etcd with r440 and m2mini). Switch one host at a time and run the etcd health check from `docs/cluster-handoff.md` after each. `switch` exiting with status 4 means a unit failed; read `systemctl --failed`. Leave etcd alone unless the user asks.
- The cluster PKI (CA keys) lives only on r440 (`~/.local/share/cluster-pki/solaris`); never copy it elsewhere or into git.

## Deploying
- Change or re-lock in this repo on a branch → CI → merge. Then on the host: `cd /etc/nixos && git pull && sudo nixos-rebuild switch --flake /etc/nixos#<host>` (m2mini adds `--override-input m2mini-vendorfw path:/boot/vendorfw`).
- Never run `nix flake update` or edit files inside `/etc/nixos` on a host.
- **c4130 intentionally lags main** until the next real vLLM change, and a GC of old generations and checkpoints must run before any c4130 switch (its root disk is ~91% full). Details in `docs/cluster-handoff.md`.
- Builds happen on r440 only: c4130 has `max-jobs = 0`; r440 builds 2 jobs × 8 cores, with nix-daemon capped at 36G and zram swap.

## Hardware
- 2× Tesla V100-PCIe-32GB, both sm_70, on the same PCIe switch with no NVLink. Driver 580, the last driver branch for Volta.
- 48 threads, 125 GB RAM, and SATA SSD RAID1.
- **CUDA 13 can't target sm_70.** Anything that compiles or ships GPU kernels must use CUDA 12.x (the stack uses 12.8). No bf16 support, so run everything as `--dtype half`.

## Stack summary (details in `hosts/c4130/vllm/CLAUDE.md`)
- The Nix code (Python env, wrappers, `vllm`/LMCache modules, Flint build) is in the fork repo (github.com/charlie-horse/vLLM, `nix/`). `hosts/c4130/vllm/default.nix` only sets host values under `services.vllm-sm70` and `services.lmcache-sm70`.
- One model runs at a time, chosen by `services.vllm-sm70.activeModel`. vLLM listens on port 8000 (`eno1` and `tailscale0`, no API key; the user relies on network policy).
- LMCache: L1 64 GB of pinned RAM, allocated in full at startup. L2 in `/var/lib/lmcache/l2`, capped at 32 GB (`services.lmcache-sm70.l2SizeGb`, set in `hosts/c4130/vllm/default.nix`); the pruner trims it to 80% once it passes 90%.
- Weights live in `/var/lib/vllm/models`, owned by `vllm`. Check scripts are in `~/archive/scripts` on c4130 (`verify_vllm.py`, `bench_vllm.py`, `kvtier_test.py`, …).
- Old `/etc/nixos` backups are in `~/archive/nixos-backups/` on each host.

## Gotchas learned the hard way
- **GPU memory budget.** The LMCache server takes ~2.2 GiB per GPU (CUDA context plus transfer staging during stores), outside vLLM's budget. Keep `gpuMemoryUtilization` at or below ~0.91, or long prefills OOM inside 1Cat's FP8 workspace.
- **KV must fit one full request.** Startup fails with "estimated maximum model length is N" if it doesn't. Lower `maxModelLen` or raise utilization (within the limit above).
- **Speculative decoding.** DFlash2 drafts (`incoai/*-DFlash2`) gave +70% decode on the 3.6-35B (111 vs 66 tok/s at 4K). They cost KV space.
- **Stopping the service.** `Restart=on-failure` brings `vllm` back after a crash or kill. Use `systemctl kill --signal=SIGKILL vllm` followed by `systemctl stop vllm`.
- **pgrep.** Over SSH, `pgrep -f <pattern>` matches its own `bash -c` command line; use `ps -ef | grep '[x]yz'` instead.
- **Thinking default.** 1Cat defaults `enable_thinking` to false. The user currently keeps that default, so requests must send `chat_template_kwargs.enable_thinking=true` to get reasoning.
- **CacheBlend** doesn't apply to hybrid GDN models; LMCache only does prefix reuse there.
