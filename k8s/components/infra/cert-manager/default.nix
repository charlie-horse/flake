# cert-manager, namespace `cert-manager`: the workload PKI. The cluster's
# own certificates come from sops files instead (secrets/pki/, docs/pki.md).
#
#   chart.nix            controller, webhook, cainjector and the CRDs
#   approver-policy.nix  the only approver
#   issuers.nix          ClusterIssuer `cluster-ca` (the deferred component
#                        `infra/cert-manager-issuers`, k8s/default.nix)
#   acme.nix             ClusterIssuers `letsencrypt-{staging,production}`
#                        (the deferred component `infra/cert-manager-acme`)
#   crds.nix             the two charts' CRDs, for the deferred components
#   settings.nix         names shared by all of them
#
# Workloads use ClusterIssuer cluster-ca; public names use
# letsencrypt-production. Docs: docs/k8s/apps.md#cert-manager
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
