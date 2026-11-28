{
  lib,
  cluster,
  k8sLib,
  ...
}:
let
  name = "router";
  namespace = "minecraft-router";
  labels."app.kubernetes.io/name" = namespace;
in
{
  imports = [ ./cobblemon.nix ];
  validation.strict = true;

  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "privileged";
  };

  resources.core.v1.ServiceAccount.mc-router = {
    metadata = { inherit namespace labels; };
  };

  resources."rbac.authorization.k8s.io".v1.ClusterRole.service-watcher = {
    rules = [
      {
        apiGroups = [ "" ];
        resources = [ "services" ];
        verbs = [
          "list"
          "watch"
        ];
      }
    ];
  };

  resources."rbac.authorization.k8s.io".v1.ClusterRoleBinding.mc-router-service-watcher = {
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io";
      kind = "ClusterRole";
      name = "service-watcher";
    };
    subjects = [
      {
        inherit namespace;
        kind = "ServiceAccount";
        name = "mc-router";
      }
    ];
  };

  resources.apps.v1.Deployment.${name} = {
    metadata = { inherit namespace labels; };

    spec = {
      replicas = 1;
      strategy.type = "Recreate";
      selector.matchLabels = labels;

      template.metadata = { inherit labels; };
      template.spec = {
        serviceAccountName = "mc-router";
        nodeSelector."kubernetes.io/hostname" = "r440";
        containers = [
          {
            inherit name;
            image = "itzg/mc-router:1.57.1";
            args = [ "--in-kube-cluster" ];
            ports = [
              {
                name = "minecraft";
                containerPort = 25565;
                hostPort = 25565;
                hostIP = cluster.nodes.r440.lanIP;
              }
            ];
            resources.requests = {
              cpu = "100m";
              memory = "50Mi";
            };
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 1000;
              runAsGroup = 1000;
              seccompProfile.type = "RuntimeDefault";
              allowPrivilegeEscalation = false;
              capabilities.drop = [ "ALL" ];
            };
          }
        ];
      };
    };
  };
}
