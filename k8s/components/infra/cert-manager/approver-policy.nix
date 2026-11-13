# cert-manager approver-policy (charts.cert-manager-approver-policy), in
# cert-manager's namespace: approves or denies every CertificateRequest
# against the CertificateRequestPolicies (CRD policy.cert-manager.io,
# rendered here into 01-customresourcedefinitions.yaml, so Flux owns it).
# cert-manager's own auto-approver is off (chart.nix `disableAutoApproval`),
# so a request no policy allows stays unapproved and is never signed.
#
# A request is approved when at least one policy whose selector matches it
# (issuer, namespace) allows every field of it, and the requester may `use`
# that policy (RBAC verb `use` on certificaterequestpolicies). The policies
# and their RBAC:
#   ClusterIssuer cluster-ca (workloads)   issuers.nix: allows anything
#   Issuers in namespace cluster-pki       components/infra/cluster-pki:
#                                          one exact policy per leaf
#
# Its webhook validates CertificateRequestPolicy objects (failurePolicy
# Fail): the policies are in deferred components, like the Issuers.
# The webhook serves a certificate approver-policy makes itself (CA in the
# Secret cert-manager-approver-policy-tls, which the chart declares empty
# because RBAC cannot grant `create` on one name; the controller fills it
# in), not one from cert-manager.
#
# Image quay.io/jetstack/cert-manager-approver-policy (multi-arch). The pod
# meets `restricted` with the chart's defaults (non-root, seccomp
# RuntimeDefault, all capabilities dropped, no privilege escalation,
# read-only root fs). Nothing tolerates c4130's GPU taint.
{
  pkgs,
  catenix,
  charts,
  kubeVersion,
  ...
}:
let
  inherit (import ./settings.nix) approverPolicyRelease;
in
{
  imports = [
    (catenix.importChart {
      inherit pkgs kubeVersion;
      release = approverPolicyRelease;
      chart = charts.cert-manager-approver-policy;
      values = {
        crds.enabled = true;
        # Leader-elected: one replica. While it is down nothing new is
        # approved (renewals wait; certs in use are untouched).
        replicaCount = 1;
        # No Prometheus in the cluster.
        app.metrics.service.enabled = false;
        resources = {
          requests = {
            cpu = "10m";
            memory = "64Mi";
          };
          limits.memory = "256Mi";
        };
      };
      noHooks = true;
    })
  ];
}
