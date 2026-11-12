# cert-manager, namespace `cert-manager`: the workload PKI. Bootstrap
# certificates (etcd, apiserver, kubelets, ...) stay files from cluster-pki
# (docs/pki.md): they must exist before the cluster, and so cert-manager,
# can run.
#
#   chart.nix      controller, webhook, cainjector and the CRDs (this
#                  component, applied by Flux's `flux-system` Kustomization)
#   issuers.nix    the CA: ClusterIssuer `selfsigned`, the root Certificate
#                  `cluster-ca` (ECDSA P-384, 10 years) and the CA
#                  ClusterIssuer `cluster-ca`. A component of its own,
#                  `infra/cert-manager-issuers`, applied by the Kustomization
#                  `cert-manager-issuers` after `flux-system`
#                  (k8s/default.nix `deferred`, components/flux/stages.nix)
#   settings.nix   names shared by both
#
# Workloads ask for a certificate with
#   issuerRef: { kind: ClusterIssuer, name: cluster-ca }
# The root's key lives only in the Secret cert-manager/cluster-ca; it is
# made in the cluster and never copied out of it.
{ ... }:
let
  inherit (import ./settings.nix) namespace;
in
{
  imports = [ ./chart.nix ];

  validation.strict = true;

  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "restricted";
    "pod-security.kubernetes.io/warn" = "restricted";
  };
}
