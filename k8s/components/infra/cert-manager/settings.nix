# Shared by the cert-manager components: the chart release (chart.nix
# renders it; issuers.nix only reads its CRDs, to type its custom resources)
# and the names workloads use.
rec {
  namespace = "cert-manager";

  release = {
    name = "cert-manager";
    inherit namespace;
  };

  # Workload certificates: `issuerRef: { kind: ClusterIssuer; name = caIssuer; }`.
  caIssuer = "cluster-ca";
  # The CA ClusterIssuer's Secret in `namespace` (tls.crt = workload
  # intermediate + root, tls.key, ca.crt = root). Created by hand, never in
  # git (issuers.nix, docs/pki-migration-plan.md).
  caSecret = "cluster-ca";
}
