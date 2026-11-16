# RuntimeClasses matching the containerd runtime handlers that
# modules/cluster/node.nix configures:
#
#   runc    every node, containerd's default handler
#   nvidia  gpu nodes only (cluster.nodes.<n>.gpu): nodeSelector
#           nvidia.com/gpu.present=true
#   crun    optional, off (`enableCrun`); only together with
#           clusterNode.crun.enable on those nodes and a node label that
#           crunNodeSelector names
{ lib, cluster, ... }:
let
  enableCrun = false;
  crunNodeSelector = {
    "runtime.neurosis/crun" = "true";
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
