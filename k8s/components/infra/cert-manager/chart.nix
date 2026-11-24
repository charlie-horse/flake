# cert-manager from the jetstack chart (charts.cert-manager): the
# controller, the webhook (validates/mutates cert-manager.io objects; the
# apiserver calls it through its Service) and the cainjector (writes the
# webhook's caBundle). The CRDs come from the chart too (crds.enabled), so
# they land in 01-customresourcedefinitions.yaml and Flux owns them.
#
# The pods meet `restricted` with the chart's defaults (non-root, seccomp
# RuntimeDefault, all capabilities dropped, no privilege escalation,
# read-only root fs).
# Nothing tolerates a node taint, so the pods stay off tainted nodes.
{
  pkgs,
  catenix,
  charts,
  kubeVersion,
  ...
}:
let
  inherit (import ./settings.nix) namespace release;

  resources = memory: {
    requests = {
      cpu = "10m";
      inherit memory;
    };
    limits.memory = "256Mi";
  };
in
{
  imports = [
    (catenix.importChart {
      inherit pkgs kubeVersion release;
      chart = charts.cert-manager;
      values = {
        crds.enabled = true;
        # Leases in our namespace, not kube-system.
        global.leaderElection.namespace = namespace;
        # No Prometheus in the cluster (no metrics Service/ServiceMonitor).
        prometheus.enabled = false;
        # A Helm post-install hook; Flux applies plain manifests (noHooks).
        startupapicheck.enabled = false;
        # Off: the built-in approver approves every request, cluster-pki's included.
        disableAutoApproval = true;

        # The controller is leader-elected: one replica; a restart only
        # delays issuance/renewal.
        replicaCount = 1;
        resources = resources "64Mi";

        # Every create/update of a cert-manager.io object goes through the
        # webhook (failurePolicy Fail): two replicas on different nodes and
        # a PDB keep it answering.
        webhook = {
          replicaCount = 2;
          podDisruptionBudget = {
            enabled = true;
            minAvailable = 1;
          };
          affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = [
            {
              weight = 100;
              podAffinityTerm = {
                topologyKey = "kubernetes.io/hostname";
                labelSelector.matchLabels = {
                  "app.kubernetes.io/instance" = release.name;
                  "app.kubernetes.io/component" = "webhook";
                };
              };
            }
          ];
          resources = resources "32Mi";
        };

        cainjector = {
          replicaCount = 1;
          resources = resources "64Mi";
        };
      };
      noHooks = true;
    })
  ];
}
