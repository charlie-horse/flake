# Memory hardening. r440 has ~46 GiB of RAM and no disk swap, and runs
# etcd + the control plane + kubelet next to c4130's remote builds. On
# 2026-11-04 two CUDA trees (2 jobs x 16 nvcc) exhausted RAM: kswapd
# stalled, journald's watchdog fired and the box hung. Three layers:
#   1. zram swap, so short spikes compress instead of stalling;
#   2. a hard memory cap on nix-daemon.service (where every build runs,
#      including c4130's: nixremote's `nix-daemon --stdio` forwards to the
#      system daemon), so a runaway build is OOM-killed inside its cgroup
#      while there are still >= 10 GiB for everything else;
#   3. builds are the first choice of the global OOM killer.
# The build concurrency itself is sized in ./builder.nix.
{ ... }:
{
  # --- zram swap -----------------------------------------------------------
  # 25% of RAM (~11.5 GiB of swap space). Compressed (zstd, ~3:1 on anon
  # pages) it costs at most ~4 GiB of real RAM when full.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 25;
    priority = 100;
  };

  # kubelet refuses to start with swap on unless failSwapOn = false (the
  # NixOS kubelet module doesn't handle swap). NoSwap: pods never swap (their
  # cgroups get memory.swap.max = 0); system daemons (etcd, apiserver,
  # builds) may. Merged with the per-node kubeletConfig from
  # cluster/definition.nix (r440 has none). Don't drop this while zram is on,
  # and swapoff before rolling back to a generation without it.
  services.kubernetes.kubelet.extraConfig = {
    failSwapOn = false;
    memorySwap.swapBehavior = "NoSwap";
  };

  # --- nix-daemon cap --------------------------------------------------------
  # Applies to the whole unit cgroup: the daemon, its connection handlers and
  # every build. MemoryHigh throttles and reclaims first; MemoryMax OOM-kills
  # inside the cgroup (the largest process, i.e. an nvcc/cicc, failing that
  # build). 46 - 36 leaves ~10 GiB for etcd, the control plane, kubelet +
  # pods, harmonia and the kernel. MemorySwapMax keeps builds from using zram
  # to slip past the cap (zram pages aren't charged to the cgroup).
  systemd.services.nix-daemon.serviceConfig = {
    MemoryAccounting = true;
    MemoryHigh = "32G";
    MemoryMax = "36G";
    MemorySwapMax = "4G";
    # Builds inherit this. If the box still runs out globally, the kernel
    # OOM killer takes a build before etcd / kube-apiserver (0) or the
    # kubelet (-999, set by itself).
    OOMScoreAdjust = 500;
  };
}
