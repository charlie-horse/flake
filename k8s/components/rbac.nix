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
#   oidc:cluster-admins
#       Members of the authentik group `cluster-admins` (blueprint in
#       components/authentik.nix) get cluster-admin when they log in with
#       OIDC. The apiserver prefixes OIDC groups with `oidc:`
#       (modules/cluster/control-plane.nix), so no OIDC token can claim a
#       built-in group such as system:masters. Inert while
#       clusterNode.oidc.enable is false.
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

    "oidc:cluster-admins" = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "cluster-admin";
      };
      subjects = [
        {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Group";
          name = "oidc:cluster-admins";
        }
      ];
    };
  };
}
