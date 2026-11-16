# cert-manager, namespace `cert-manager`: the workload PKI. Bootstrap
# certificates (etcd, apiserver, kubelets, ...) reach the nodes as sops
# files (secrets/pki/, docs/pki.md): they must exist before the cluster, and
# so cert-manager, can run.
#
#   chart.nix            controller, webhook, cainjector and the CRDs
#   approver-policy.nix  the only approver
#   issuers.nix          ClusterIssuer `cluster-ca` (the deferred component
#                        `infra/cert-manager-issuers`, k8s/default.nix)
#   crds.nix             the two charts' CRDs, for the deferred components
#   settings.nix         names shared by all of them
#
# Workloads use issuerRef: { kind: ClusterIssuer, name: cluster-ca }.
# Docs: docs/k8s/apps.md#cert-manager
{ ... }:
let
  inherit (import ./settings.nix) namespace;
in
{
  imports = [
    ./chart.nix
    ./approver-policy.nix
  ];

  validation.strict = true;

  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "restricted";
    "pod-security.kubernetes.io/warn" = "restricted";
  };
}
