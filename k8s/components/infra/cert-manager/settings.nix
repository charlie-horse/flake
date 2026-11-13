# Shared by the cert-manager components: the chart releases (chart.nix and
# approver-policy.nix render them; issuers.nix and components/infra/
# cluster-pki only read their CRDs, through crds.nix, to type their custom
# resources) and the names workloads use.
rec {
  namespace = "cert-manager";

  release = {
    name = "cert-manager";
    inherit namespace;
  };

  # approver-policy (approver-policy.nix), in cert-manager's namespace.
  approverPolicyRelease = {
    name = "cert-manager-approver-policy";
    inherit namespace;
  };

  # The cert-manager controller's ServiceAccount (the chart names it after
  # the release). It creates the CertificateRequest of every Certificate,
  # so it is the requester approver-policy checks for `use` of a
  # CertificateRequestPolicy.
  controllerServiceAccount = release.name;

  # Workload certificates: `issuerRef: { kind: ClusterIssuer; name = caIssuer; }`.
  caIssuer = "cluster-ca";
  # The CA ClusterIssuer's Secret in `namespace` (tls.crt = workload
  # intermediate + root, tls.key, ca.crt = root). From sops,
  # k8s/secrets/cert-manager/cluster-ca.sops.yaml (issuers.nix).
  caSecret = "cluster-ca";
}
