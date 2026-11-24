# authentik (SSO / OIDC identity provider), namespace `authentik`.
#
#   chart.nix       server + worker (authentik Helm chart), one of each per node
#   postgres.nix    PostgreSQL StatefulSet, data in a node-local volume
#   backup.nix      daily `pg_dump -Fc` CronJob to a node-local volume
#   blueprints.nix  OIDC clients and groups (blueprints/*.yaml)
#
# The Secret `authentik-secrets` (settings.nix) is sops-encrypted in
# k8s/secrets/authentik/; until it is applied the pods wait in
# CreateContainerConfigError. Public at cluster.authentik.host through
# apps/cloudflared. Docs: docs/k8s/apps.md#authentik
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
