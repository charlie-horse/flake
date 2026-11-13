# The only approver (chart.nix disables cert-manager's): a request no policy allows is never signed.
{
  pkgs,
  catenix,
  charts,
  kubeVersion,
  ...
}:
let
  inherit (import ./settings.nix) approverPolicyRelease;
in
{
  imports = [
    (catenix.importChart {
      inherit pkgs kubeVersion;
      release = approverPolicyRelease;
      chart = charts.cert-manager-approver-policy;
      values = {
        crds.enabled = true;
        # Leader-elected; while it is down, renewals wait and certs in use are untouched.
        replicaCount = 1;
        # No Prometheus in the cluster.
        app.metrics.service.enabled = false;
        resources = {
          requests = {
            cpu = "10m";
            memory = "64Mi";
          };
          limits.memory = "256Mi";
        };
      };
      noHooks = true;
    })
  ];
}
