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
  # The root CA's Certificate and its Secret (tls.crt, tls.key, ca.crt) in
  # `namespace`, the CA ClusterIssuer's signing key. Never copied anywhere.
  caSecret = "cluster-ca";
  # Signs the root CA once (and on renewal); nothing else should use it.
  selfSignedIssuer = "selfsigned";
}
