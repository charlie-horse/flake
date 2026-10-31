# Cluster RBAC that NixOS would normally create through the addon manager
# (services.kubernetes.addonManager.bootstrapAddons, disabled here: see
# modules/cluster/default.nix).
#
#   system:kube-apiserver:kubelet-api-admin
#       The apiserver's kubelet client cert (apiserver-kubelet-client-<n>,
#       CN=system:kube-apiserver, no O) must be allowed by the kubelets'
#       Webhook authorizer, or `kubectl logs/exec/attach/port-forward`,
#       `top` and node proxying return 403. Same binding as nixpkgs
#       kubernetes/apiserver.nix (apiserver-kubelet-api-admin-crb).
#
# Bootstrap: apply this file with the admin cert together with the network
# and DNS (k8s/README.md); Flux keeps it afterwards.
{ ... }:
{
  validation.strict = true;

  resources."rbac.authorization.k8s.io".v1.ClusterRoleBinding = {
    "system:kube-apiserver:kubelet-api-admin" = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "system:kubelet-api-admin";
      };
      subjects = [
        {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "User";
          name = "system:kube-apiserver";
        }
      ];
    };
  };
}
