# authentik (SSO / OIDC identity provider), namespace `authentik`.
#
#   chart.nix       server + worker (authentik Helm chart), one of each per
#                   node, so login survives any one node being down
#   postgres.nix    PostgreSQL 17 StatefulSet, single instance, data on
#                   m2mini's NVMe (hostPath PV)
#   backup.nix      daily `pg_dump -Fc` CronJob to r440 (14 kept)
#   blueprints.nix  OIDC clients and groups (blueprints/*.yaml)
#
# Secrets are NOT in git: the hand-made Secret `authentik-secrets`
# (settings.nix; k8s/README.md). Until it exists the pods wait in
# CreateContainerConfigError; nothing else breaks.
#
# Public at https://auth.neuros.is (cluster.authentik.host) through the
# cluster's tunnel (apps/cloudflared) to Service authentik-server at the
# fixed ClusterIP cluster.authentik.serviceIP. Without the tunnel:
#   kubectl -n authentik port-forward svc/authentik-server 9000:80
{ ... }:
let
  inherit (import ./settings.nix) namespace;
in
{
  imports = [
    ./chart.nix
    ./postgres.nix
    ./backup.nix
    ./blueprints.nix
  ];

  validation.strict = true;

  # baseline: the postgres entrypoint starts as root (postgres.nix); the
  # server and worker meet `restricted`.
  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "baseline";
    "pod-security.kubernetes.io/warn" = "restricted";
  };
}
