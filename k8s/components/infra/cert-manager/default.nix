# cert-manager, namespace `cert-manager`: the workload PKI. Bootstrap
# certificates (etcd, apiserver, kubelets, ...) stay files from cluster-pki
# (docs/pki.md): they must exist before the cluster, and so cert-manager,
# can run.
#
#   chart.nix      controller, webhook, cainjector and the CRDs (this
#                  component, applied by Flux's `flux-system` Kustomization)
#   approver-policy.nix
#                  approver-policy and its CRD (this component): approves
#                  CertificateRequests by CertificateRequestPolicy;
#                  cert-manager's own auto-approver is off (chart.nix)
#   issuers.nix    the CA ClusterIssuer `cluster-ca` over the Secret
#                  `cluster-ca` from sops (the workload intermediate under
#                  the YubiKey root, docs/pki-migration-plan.md) and its
#                  allow-all CertificateRequestPolicy. A component
#                  of its own, `infra/cert-manager-issuers`, applied by the
#                  Kustomization
#                  `cert-manager-issuers` after `flux-system`
#                  (k8s/default.nix `deferred`, components/flux/stages.nix)
#   crds.nix       the two charts' CRDs, for the deferred components
#   settings.nix   names shared by all of them
#
# Workloads ask for a certificate with
#   issuerRef: { kind: ClusterIssuer, name: cluster-ca }
# The intermediate's key lives only in the Secret cert-manager/cluster-ca,
# which nothing in git declares.
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
