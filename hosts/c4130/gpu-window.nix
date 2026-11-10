# GPU window on c4130: vllm.service is stopped at 22:00 and started again at
# 05:55 (America/New_York), so charlie can use both V100s in between.
#
# - gpu-window-start: stops vllm.service (and nothing else).
# - gpu-window-end:   kills the GPU processes owned by user `charlie`, then
#                     starts vllm.service. 06:00 is the deadline.
#
# Both are oneshot services run by timers with Persistent = false, so a
# missed run (host down at 22:00 or 05:55) is not replayed at boot. A failing
# oneshot ends up `failed` in systemd (`systemctl --failed`). vllm.service is
# targeted by name only; nothing here touches the Kubernetes services.
#
# Notes:
# - Only the vllm.service is stopped. vllm-lmcache.service stays up overnight
#   (about 328 MiB per GPU and 64 GB of pinned RAM stay allocated).
# - The timers do not know the window state: a `nixos-rebuild switch` or a
#   reboot between 22:00 and 06:00 starts vllm.service again (it is enabled),
#   and the GPUs are then taken. Stop it again by hand, or switch outside the
#   window.
# - "charlie's" GPU processes means PIDs in user-<uid>.slice (a login session,
#   tmux, a user service). A GPU pod run by kubelet as the same uid is in a
#   kubepods cgroup, is not matched, and is only logged as skipped.
{ config, lib, pkgs, ... }:
let
  gpuUser = "charlie";
  nvidiaSmi = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi";
  systemctl = "${config.systemd.package}/bin/systemctl";

  endScript = pkgs.writeShellScript "gpu-window-end" ''
    set -u
    rc=0

    # PIDs of compute processes on the GPUs, then keep only those owned by
    # ${gpuUser}. A failing nvidia-smi is an error, but vllm.service is still
    # started below.
    if ! pids=$(${nvidiaSmi} --query-compute-apps=pid --format=csv,noheader,nounits); then
      echo "nvidia-smi failed; GPU processes not checked" >&2
      rc=1
      pids=""
    fi

    # Kill only PIDs in ${gpuUser}'s user slice (user-<uid>.slice). The owner
    # alone is not enough: a GPU pod from kubelet's device plugin can run as
    # the same uid. Every other GPU PID is logged and left alone.
    uid=$(${pkgs.coreutils}/bin/id -u ${gpuUser}) || { echo "no user ${gpuUser}" >&2; uid=""; rc=1; }
    mine=""
    for pid in $pids; do
      owner=$(${pkgs.coreutils}/bin/stat -c %U "/proc/$pid" 2>/dev/null) || continue
      cg=$(${pkgs.coreutils}/bin/cat "/proc/$pid/cgroup" 2>/dev/null) || continue
      if [ -n "$uid" ] && [ "$owner" = "${gpuUser}" ] && \
         printf '%s\n' "$cg" | ${pkgs.gnugrep}/bin/grep -q "/user.slice/user-$uid.slice/"; then
        mine="$mine $pid"
      else
        echo "skipping GPU pid $pid (owner $owner, cgroup $(printf '%s' "$cg" | ${pkgs.coreutils}/bin/head -n1))"
      fi
    done

    if [ -n "$mine" ]; then
      echo "stopping ${gpuUser}'s GPU processes:$mine"
      kill -TERM $mine 2>/dev/null || true
      for _ in $(seq 1 15); do
        alive=""
        for pid in $mine; do kill -0 "$pid" 2>/dev/null && alive="$alive $pid"; done
        [ -z "$alive" ] && break
        sleep 1
      done
      if [ -n "$alive" ]; then
        echo "still running after 15 s, sending SIGKILL:$alive"
        kill -KILL $alive 2>/dev/null || true
        sleep 2
      fi
    fi

    ${systemctl} start vllm.service || rc=1
    exit $rc
  '';
in
{
  systemd.services.gpu-window-start = {
    description = "GPU window: stop vllm.service";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${systemctl} stop vllm.service";
      TimeoutStartSec = "5min";
    };
  };

  systemd.services.gpu-window-end = {
    description = "GPU window: stop ${gpuUser}'s GPU processes, start vllm.service";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = endScript;
      TimeoutStartSec = "10min";
    };
  };

  systemd.timers.gpu-window-start = {
    description = "GPU window opens (22:00 America/New_York)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 22:00:00 America/New_York";
      Persistent = false;
      AccuracySec = "1s";
    };
  };

  systemd.timers.gpu-window-end = {
    description = "GPU window closes (05:55 America/New_York)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 05:55:00 America/New_York";
      Persistent = false;
      AccuracySec = "1s";
    };
  };
}
