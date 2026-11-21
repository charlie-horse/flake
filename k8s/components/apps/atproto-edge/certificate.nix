# The edge's certificate, deferred component `apps/atproto-edge-certs`:
# Certificate atproto-edge/at-wildcard-tls for *.<handleDomain> from the
# ClusterIssuer letsencrypt-production (ACME DNS-01 via Cloudflare).
# Deferred because cert-manager's webhook validates every cert-manager.io
# object (failurePolicy Fail). Renewal check: docs/k8s/apps.md#atproto-tls-edge
{
  pkgs,
  catenix,
  charts,
  kubeVersion,
  cluster,
  ...
}:
let
  crds = import ../../infra/cert-manager/crds.nix {
    inherit
      pkgs
      catenix
      charts
      kubeVersion
      ;
  };
in
{
  imports = [ (catenix.crdModule crds.certManager) ];

  validation.strict = true;

  resources."cert-manager.io".v1.Certificate.at-wildcard-tls = {
    metadata.namespace = "atproto-edge";
    spec = {
      secretName = "at-wildcard-tls";
      dnsNames = [ "*.${cluster.tranquilPds.handleDomain}" ];
      issuerRef = {
        group = "cert-manager.io";
        kind = "ClusterIssuer";
        name = "letsencrypt-production";
      };
      privateKey = {
        algorithm = "ECDSA";
        size = 256;
        rotationPolicy = "Always";
      };
    };
  };
}
