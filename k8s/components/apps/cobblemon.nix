{
  lib,
  cluster,
  k8sLib,
  ...
}:
let
  namespace = "minecraft";
  name = "cobblemon";
  labels."app.kubernetes.io/name" = "cobblemon";

  mcPort = 25565;

  env = {
    EULA = "TRUE";
    MEMORY = "16G";
    TYPE = "NEOFORGE";
    VERSION = "1.21.1";
    MODRINTH_PROJECTS = "cobblemon";
    MODRINTH_DOWNLOAD_DEPENDENCIES = "required";
  };

  cobblemonContainer = {
    inherit name;
    image = "itzg/minecraft-server:2026.11.1-java21";
    env = lib.mapAttrsToList (n: v: {
      name = n;
      value = v;
    }) env;

    ports = [
      {
        name = "minecraft";
        containerPort = mcPort;
        hostPort = mcPort;
        hostIP = cluster.nodes.r440.lanIP;
      }
    ];

    startupProbe = {
      exec.command = [ "mc-health" ];
      periodSeconds = 10;
      failureThreshold = 90;
      timeoutSeconds = 5;
    };

    readinessProbe = {
      exec.command = [ "mc-health" ];
      periodSeconds = 10;
      timeoutSeconds = 5;
    };

    livenessProbe = {
      exec.command = [ "mc-health" ];
      periodSeconds = 30;
      failureThreshold = 5;
      timeoutSeconds = 5;
    };

    securityContext = {
      runAsNonRoot = true;
      runAsUser = 1000;
      runAsGroup = 1000;
      seccompProfile.type = "RuntimeDefault";
      allowPrivilegeEscalation = false;
      capabilities.drop = [ "ALL" ];
    };

    resources = {
      requests = {
        cpu = "250m";
        memory = "8Gi";
      };
      limits.memory = "20Gi";
    };

    volumeMounts = [
      {
        name = "data";
        mountPath = "/data";
      }
    ];
  };
in
{
  imports = [
    (k8sLib.localVolume {
      inherit namespace name;
      node = "r440";
      path = "/var/lib/minecraft/cobblemon";
      size = "50Gi";
    })
  ];

  validation.strict = true;

  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "privileged";
  };

  resources.apps.v1.Deployment.${name} = {
    metadata = { inherit namespace labels; };

    spec = {
      replicas = 1;
      strategy.type = "Recreate";
      selector.matchLabels = labels;

      template.metadata = { inherit labels; };
      template.spec = {
        nodeSelector."kubernetes.io/hostname" = "r440";
        containers = [ cobblemonContainer ];
        volumes = [
          {
            name = "data";
            persistentVolumeClaim.claimName = name;
          }
        ];
      };
    };
  };

  resources.core.v1.Service.${name} = {
    metadata = { inherit namespace labels; };
    spec = {
      clusterIP = cluster.cobblemon.serviceIP;
      selector = labels;
      ports = [
        {
          name = "minecraft";
          port = mcPort;
          targetPort = mcPort;
        }
      ];
    };
  };
}
