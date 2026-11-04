# etcd on its own spindle, and builds yielding disk time to it.
#
# Why: on 2026-11-04 r440's etcd logged ~17 "apply request took too long"
# per minute. Not the network (tailscale direct): the local disk. etcd's
# WAL + backend lived on / (sdc2, one 5400 rpm IronWolf) together with
# /nix/store (c4130's CUDA builds, harmonia), containerd, journald and
# podman, so every WAL fsync queued behind build I/O on mq-deadline.
#
# Fix, in three parts:
#   1. /var/lib/etcd is its own ext4 on sdd (Hitachi HDS721010KLA330,
#      7200 rpm, whole disk, label R440-ETCD), so WAL fsyncs only wait for
#      etcd's own writes. Migration: docs/cluster-handoff.md, section
#      "r440: etcd on its own disk (sdd)". The filesystem must exist BEFORE
#      switching to this config.
#   2. BFQ on every rotational disk, so cgroup IO weights are honoured
#      (mq-deadline ignores them). This also makes the existing
#      nix.daemonIOSchedClass = "idle" (./builder.nix) effective.
#   3. etcd gets a high IO/CPU weight, nix-daemon (every build) a tiny one.
#
# sdd is a ~15-year-old desktop disk: a stop-gap. The real fix is a small
# SSD (even a cheap SATA one has fsync latency ~100x better than any HDD)
# for /var/lib/etcd; then change only the label/device below.
#
# Not used: sda2 (5.5T ext4, unmounted, unknown content) and sdb (WD Green,
# aggressive head parking: idle->park->spin-up stalls are poison for fsync).
{ ... }:
{
  # --- 1. Own filesystem ------------------------------------------------------
  # nofail (+ a short device timeout): if the old disk dies, r440 still boots
  # (sshd, harmonia, the builder) instead of dropping into emergency mode;
  # only etcd stays down (RequiresMountsFor below). With nofail the mount is
  # only wanted by local-fs.target, not ordered before it, so etcd's own
  # dependency is what guarantees the ordering.
  fileSystems."/var/lib/etcd" = {
    device = "/dev/disk/by-label/R440-ETCD";
    fsType = "ext4";
    options = [ "noatime" "nofail" "x-systemd.device-timeout=30s" ];
  };

  # etcd must never start on an empty /var/lib/etcd (i.e. on the bare mount
  # point of the root fs when the disk is missing). The cluster module sets
  # ETCD_INITIAL_CLUSTER_STATE=new (only read when the data dir is empty), so
  # an empty dir makes r440 bootstrap a brand-new single-member raft log with
  # the same member/cluster IDs as the real one: at best the leader rejects
  # it or it panics ("tocommit is out of range"), at worst it diverges, and
  # either way it has silently lost its data. RequiresMountsFor =
  # Requires= + After= var-lib-etcd.mount: if the mount fails, etcd fails
  # with a dependency error and Restart=always does not retry it.
  # (The NixOS etcd module sets no mount dependency of its own.)
  systemd.services.etcd.unitConfig.RequiresMountsFor = [ "/var/lib/etcd" ];

  # The NixOS etcd module already has a tmpfiles `d /var/lib/etcd 0700 etcd`
  # rule (group left as "-"); add the group so the mounted fs root is
  # etcd:etcd 0700 even if the rsync in the runbook didn't preserve it.
  # Same rule, merged: no second tmpfiles line for the path.
  systemd.tmpfiles.settings."10-etcd"."/var/lib/etcd".d.group = "etcd";

  # --- 2. BFQ on rotational disks -------------------------------------------
  # CONFIG_IOSCHED_BFQ=m in the 26.05 kernel (common-config.nix), so load it
  # at boot; the udev write would also autoload it, this just avoids a race.
  boot.kernelModules = [ "bfq" ];
  # sd* only (zram/loop/nvme untouched); applies on add and on `change`
  # (`udevadm trigger` after a switch).
  services.udev.extraRules = ''
    ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
  '';

  # --- 3. IO / CPU weights ----------------------------------------------------
  # cgroup v2 weights (1..10000, default 100), relative between siblings in
  # system.slice. IOWeight needs BFQ (or io.cost) on the disk to do anything.
  # No Nice/IOSchedulingClass=realtime for etcd: the weight already wins
  # against builds, and realtime IO could starve journald/sshd on sdc.
  systemd.services.etcd.serviceConfig = {
    IOWeight = 1000;
    CPUWeight = 1000;
  };
  # Merged with ./memory.nix's nix-daemon serviceConfig (memory caps) and
  # nix.daemonIOSchedClass/CPUSchedPolicy from ./builder.nix.
  systemd.services.nix-daemon.serviceConfig.IOWeight = 10;

  # --- Metrics ----------------------------------------------------------------
  # Plain-HTTP /metrics + /health on localhost only, for checking WAL fsync
  # latency (etcd_disk_wal_fsync_duration_seconds) without client certs.
  # Not reachable from outside: 127.0.0.1, so the firewall is unaffected.
  # Becomes ETCD_LISTEN_METRICS_URLS (extraConf is attrsOf str, merged with
  # anything else setting it; modules/cluster/etcd.nix sets none).
  services.etcd.extraConf.LISTEN_METRICS_URLS = "http://127.0.0.1:2381";
}
