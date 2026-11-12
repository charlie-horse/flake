# StorageClass `local`: statically provisioned, node-local volumes (no
# provisioner). The cluster has no network storage, so a stateful app gets
# a hostPath PersistentVolume pinned to one node by nodeAffinity and
# pre-bound to its claim (claimRef); see k8s/lib.nix (localVolume).
#
# WaitForFirstConsumer: a claim binds when its pod is scheduled, so the
# scheduler honours the PV's node affinity. Reclaim policy is set per PV
# (Retain everywhere: deleting a claim never deletes data).
{
  validation.strict = true;

  resources."storage.k8s.io".v1.StorageClass.local = {
    provisioner = "kubernetes.io/no-provisioner";
    volumeBindingMode = "WaitForFirstConsumer";
    reclaimPolicy = "Retain";
  };
}
