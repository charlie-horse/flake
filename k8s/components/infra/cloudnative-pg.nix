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
# One replica per node (required anti-affinity, every node taint tolerated,
# multi-arch image): one leader reconciles, every replica serves the
# webhooks. Rolling updates replace one pod at a time (maxSurge 0: a surge
# pod would have no free node); the PDB keeps all but one up.
#
# The pods meet `restricted` with the chart's defaults (uid 10001, seccomp
# RuntimeDefault, all capabilities dropped, read-only root fs).
# Docs: docs/k8s/apps.md#cloudnativepg
{
  pkgs,
  catenix,
  charts,
  cluster,
  kubeVersion,
  k8sLib,
  lib,
  ...
}:
let
  namespace = "cnpg-system";
  release = {
    name = "cnpg";
    inherit namespace;
  };
  # The chart's selector labels (chart name, release name).
  selector = {
    "app.kubernetes.io/name" = "cloudnative-pg";
    "app.kubernetes.io/instance" = release.name;
  };
in
{
  imports = [
    (catenix.importChart {
      inherit pkgs kubeVersion release;
      chart = charts.cloudnative-pg;
      values = {
        fullnameOverride = "cnpg";
        crds.create = true;
        replicaCount = lib.length (lib.attrNames cluster.nodes);
        updateStrategy = {
          type = "RollingUpdate";
          rollingUpdate = {
            maxSurge = 0;
            maxUnavailable = 1;
          };
        };
        affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution = [
          {
            topologyKey = "kubernetes.io/hostname";
            labelSelector.matchLabels = selector;
          }
        ];
        tolerations = k8sLib.nodeTolerations;
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

  resources.policy.v1.PodDisruptionBudget.cnpg = {
    metadata = { inherit namespace; };
    spec = {
      maxUnavailable = 1;
      selector.matchLabels = selector;
    };
  };

  validation.strict = true;

  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "restricted";
    "pod-security.kubernetes.io/warn" = "restricted";
  };
}
