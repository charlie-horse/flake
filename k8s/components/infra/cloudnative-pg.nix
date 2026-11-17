# CloudNativePG operator, namespace `cnpg-system`: the PostgreSQL operator
# from the cloudnative-pg chart (charts.cloudnative-pg). It watches every
# namespace (config.clusterWide) for postgresql.cnpg.io objects; this
# component runs the operator only.
#
# The CRDs come from the chart (crds.create), so they land in
# 01-customresourcedefinitions.yaml and Flux owns them. The operator serves
# its own webhooks (failurePolicy Fail) and writes their caBundle itself; the
# rendered webhook configurations carry none, so Flux never reverts it.
#
# The pod meets `restricted` with the chart's defaults (uid 10001, seccomp
# RuntimeDefault, all capabilities dropped, read-only root fs). Nothing
# tolerates c4130's GPU taint: it runs on r440 or m2mini (multi-arch image).
# Docs: docs/k8s/apps.md#cloudnativepg
{
  pkgs,
  catenix,
  charts,
  kubeVersion,
  ...
}:
let
  namespace = "cnpg-system";
in
{
  imports = [
    (catenix.importChart {
      inherit pkgs kubeVersion;
      chart = charts.cloudnative-pg;
      release = {
        name = "cnpg";
        inherit namespace;
      };
      values = {
        fullnameOverride = "cnpg";
        crds.create = true;
        # Leader-elected: one replica; a restart only delays reconciles (and
        # rejects postgresql.cnpg.io writes until it is back).
        replicaCount = 1;
        resources = {
          requests = {
            cpu = "50m";
            memory = "128Mi";
          };
          limits.memory = "512Mi";
        };
        monitoring = {
          podMonitorEnabled = false;
          grafanaDashboard.create = false;
        };
      };
      noHooks = true;
    })
  ];

  validation.strict = true;

  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "restricted";
    "pod-security.kubernetes.io/warn" = "restricted";
  };
}
