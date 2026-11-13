# Shared by the cert-manager components and components/infra/cluster-pki:
# the chart releases and the names workloads use.
rec {
  namespace = "cert-manager";

  release = {
    name = "cert-manager";
    inherit namespace;
  };

  approverPolicyRelease = {
    name = "cert-manager-approver-policy";
    inherit namespace;
  };

  # Named after the release by the chart. It requests every Certificate, so
  # approver-policy checks its `use` of a policy.
  controllerServiceAccount = release.name;

  # Workload certificates: `issuerRef: { kind: ClusterIssuer; name = caIssuer; }`.
  caIssuer = "cluster-ca";
  # The CA ClusterIssuer's Secret in `namespace` (tls.crt = workload
  # intermediate + root, tls.key, ca.crt = root). From sops,
  # k8s/secrets/cert-manager/cluster-ca.sops.yaml (issuers.nix).
  caSecret = "cluster-ca";
}
