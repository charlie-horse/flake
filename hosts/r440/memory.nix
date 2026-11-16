# Memory limits: zram swap, a hard memory cap on nix-daemon (every build,
# c4130's included), and builds first in line for the OOM killer. Build
# concurrency is in ./builder.nix.
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
