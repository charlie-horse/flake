# Helpers shared by the catenix components (k8s/components/*), passed to
# every component as the `k8sLib` module argument by k8s/render.nix.
{ lib, cluster }:
{
  # A node-local volume: a hostPath PersistentVolume pinned to `node` and
  # pre-bound (claimRef) to the claim of the same name in `namespace`, plus
  # that claim. StorageClass `local` (components/infra/local-storage.nix), reclaim
  # Retain: deleting the claim or the component never deletes the data.
  # Returns a module fragment; put it in `imports`.
  localVolume =
    {
      namespace,
      name,
      node,
      path,
      size,
    }:
    {
      resources.core.v1.PersistentVolume.${name}.spec = {
        capacity.storage = size;
        accessModes = [ "ReadWriteOnce" ];
        persistentVolumeReclaimPolicy = "Retain";
        storageClassName = "local";
        volumeMode = "Filesystem";
        hostPath = {
          inherit path;
          type = "DirectoryOrCreate";
        };
        claimRef = {
          inherit namespace name;
        };
        nodeAffinity.required.nodeSelectorTerms = [
          {
            matchExpressions = [
              {
                key = "kubernetes.io/hostname";
                operator = "In";
                values = [ node ];
              }
            ];
          }
        ];
      };
      resources.core.v1.PersistentVolumeClaim.${name} = {
        metadata = { inherit namespace; };
        spec = {
          accessModes = [ "ReadWriteOnce" ];
          storageClassName = "local";
          volumeName = name;
          resources.requests.storage = size;
        };
      };
    };

  # Tolerations for every taint any node carries (cluster/definition.nix,
  # nodes.<n>.taints), for workloads that must run on every node (one
  # replica per node).
  nodeTolerations = lib.unique (
    lib.concatMap (
      n:
      lib.mapAttrsToList (_: t: {
        inherit (t) key value effect;
        operator = "Equal";
      }) (n.taints or { })
    ) (lib.attrValues cluster.nodes)
  );

  # A chart `patch` (catenix.importChart) that pins the Service `service` to
  # a fixed ClusterIP. It also sets Flux's force annotation, so Flux
  # recreates the Service when the IP changes (ClusterIP is immutable).
  fixedServiceIP =
    { service, ip }:
    manifest:
    if manifest.kind == "Service" && manifest.metadata.name == service then
      lib.recursiveUpdate manifest {
        metadata.annotations."kustomize.toolkit.fluxcd.io/force" = "enabled";
        spec.clusterIP = ip;
      }
    else
      manifest;
}
