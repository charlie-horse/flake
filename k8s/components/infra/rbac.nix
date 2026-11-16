# Cluster RBAC that NixOS would normally create through the addon manager
# (services.kubernetes.addonManager.bootstrapAddons, disabled here: see
# modules/cluster/default.nix).
#
#   system:kube-apiserver:kubelet-api-admin
#       lets the apiserver's kubelet client cert (CN=system:kube-apiserver)
#       past the kubelets' Webhook authorizer (else logs/exec/port-forward 403)
#   oidc:cluster-admins
#       authentik group `cluster-admins` -> cluster-admin for OIDC logins
#       (groups are prefixed `oidc:`); inert without `oidc` in cluster/definition.nix
#
# Bootstrap applies it by hand with the network and DNS; Flux keeps it
# afterwards.
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
