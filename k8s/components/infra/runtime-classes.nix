# RuntimeClasses matching the containerd runtime handlers that
# modules/cluster/node.nix configures:
#
#   runc    every node, containerd's default handler. Pods without a
#           runtimeClassName use it already; the object only lets a pod
#           name it explicitly.
#   nvidia  gpu nodes only (cluster.nodes.<n>.gpu = true): runc wrapped by
#           nvidia-container-runtime in CDI mode. Its scheduling
#           nodeSelector keeps such pods on nodes labelled
#           nvidia.com/gpu.present=true (node.nix sets that label from
#           `gpu`).
#   crun    optional, off (`enableCrun` below). Turn it on only together
#           with `clusterNode.crun.enable = true` on the nodes that should
#           run it, and give those nodes a label to select (e.g.
#           cluster.nodes.<n>.labels."runtime.solaris/crun" = "true"),
#           which crunNodeSelector must then name.
{ lib, cluster, ... }:
let
  enableCrun = false;
  crunNodeSelector = {
    "runtime.solaris/crun" = "true";
  };

  gpuNodes = lib.attrNames (lib.filterAttrs (_: n: n.gpu or false) cluster.nodes);
in
{
  validation.strict = true;

  resources."node.k8s.io".v1.RuntimeClass = {
    runc.handler = "runc";
  }
  // lib.optionalAttrs (gpuNodes != [ ]) {
    nvidia = {
      handler = "nvidia";
      scheduling.nodeSelector."nvidia.com/gpu.present" = "true";
    };
  }
  // lib.optionalAttrs enableCrun {
    crun = {
      handler = "crun";
      scheduling.nodeSelector = crunNodeSelector;
    };
  };
}
