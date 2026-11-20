# ATProto services, one namespace `atproto`:
#
#   tranquil-pds/  Tranquil PDS, logins through authentik
#   tangled/       Tangled knot
#   atcr/          ATCR AppView and hold (OCI registry)
#
# Public through apps/cloudflared (hosts in cluster/definition.nix).
# Docs: docs/k8s/apps.md#atproto-services
{ ... }:
let
  namespace = "atproto";
in
{
  imports = [
    ./tranquil-pds
    ./tangled
    ./atcr
  ];

  validation.strict = true;

  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "baseline";
    "pod-security.kubernetes.io/warn" = "restricted";
  };
}
