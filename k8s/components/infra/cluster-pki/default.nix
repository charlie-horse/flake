# The cluster's bootstrap PKI, issued in the cluster (docs/pki-migration-plan.md,
# phase 2): the three bootstrap intermediates (k8s, etcd, front-proxy) as
# cert-manager Issuers in their own namespace, `cluster-pki`, and one
# Certificate per leaf that pkgs/cluster-pki makes today, per node.
#
#   default.nix    the namespace (this component, `infra/cluster-pki`,
#                  applied by `flux-system`, so the Kustomization `secrets`
#                  can put the CA Secrets in it)
#   issuers.nix    Issuers, Certificates, CertificateRequestPolicies and
#                  their RBAC: component `infra/cluster-pki-issuers`,
#                  deferred (Kustomization `cluster-pki-issuers`), like
#                  cert-manager's issuers.nix
#   leaves.nix     the leaves, from cluster/definition.nix, as cluster-pki
#                  issues them
#   export.nix     the export job (P2): CronJob, ServiceAccount and a
#                  get-only Role, imported here (applied by `flux-system`
#                  too: nothing in it goes through cert-manager's webhook)
#   settings.nix   names shared by all of them
#
# Namespaced Issuers: only a Certificate (or CertificateRequest) in this
# namespace can use them, so who may create those here is who may ask for a
# bootstrap cert. What they get is limited by the policies (issuers.nix).
# The only pod here is the daily export job (export.nix).
{ ... }:
let
  inherit (import ./settings.nix) namespace;
in
{
  imports = [ ./export.nix ];

  validation.strict = true;

  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "restricted";
    "pod-security.kubernetes.io/warn" = "restricted";
  };
}
