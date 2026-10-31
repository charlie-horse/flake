# NVIDIA device plugin: advertises nvidia.com/gpu on the gpu nodes
# (cluster.nodes.<n>.gpu; today c4130's 2x V100). Pinned to them by the
# nodeSelector nvidia.com/gpu.present=true, the label node.nix gives gpu
# nodes; GPU feature discovery and NFD (the chart's optional extras) stay
# off. This is the one image not required to be multi-arch.
#
# It runs under the nvidia RuntimeClass (00-runtime-classes), i.e.
# nvidia-container-runtime in CDI mode, which injects the driver and
# devices (NVIDIA_VISIBLE_DEVICES=all) so NVML works in the plugin. Pods
# that request nvidia.com/gpu must also set runtimeClassName: nvidia; the
# runtime turns the NVIDIA_VISIBLE_DEVICES the plugin hands out
# (deviceListStrategy envvar) into CDI devices.
{
  pkgs,
  catenix,
  charts,
  kubeVersion,
  ...
}:
let
  gpuSelector."nvidia.com/gpu.present" = "true";
in
{
  imports = [
    (catenix.importChart {
      inherit pkgs kubeVersion;
      chart = charts.nvidia-device-plugin;
      release = {
        name = "nvidia-device-plugin";
        namespace = "kube-system";
      };
      values = {
        fullnameOverride = "nvidia-device-plugin";
        runtimeClassName = "nvidia";
        nodeSelector = gpuSelector;
        # Replace the chart's NFD-or-label affinity: the label is enough.
        affinity = null;
        gfd.enabled = false;
        nfd.enabled = false;
        deviceListStrategy = "envvar";
      };
      # The chart always renders the MPS control daemon (it only schedules
      # on nodes labelled nvidia.com/mps.capable); MPS isn't used here.
      patch =
        m:
        if m.kind == "DaemonSet" && m.metadata.name == "nvidia-device-plugin-mps-control-daemon" then
          null
        else
          m;
    })
  ];

  validation.strict = true;
}
