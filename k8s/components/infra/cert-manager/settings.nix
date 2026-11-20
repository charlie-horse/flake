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

  # Public certificates (acme.nix): ClusterIssuer name -> ACME directory.
  acmeIssuers = {
    letsencrypt-staging = "https://acme-staging-v02.api.letsencrypt.org/directory";
    letsencrypt-production = "https://acme-v02.api.letsencrypt.org/directory";
  };
  # The only zone the ACME issuers solve DNS-01 for, and so the only names
  # their policies allow (the zone and anything under it).
  acmeZone = "neuros.is";
  # Cloudflare API token (Zone:DNS:Edit on acmeZone) in `namespace`, from
  # sops: k8s/secrets/cert-manager/cloudflare-api-token.sops.yaml.
  cloudflareTokenSecret = "cloudflare-api-token";
  cloudflareTokenKey = "api-token";
}
