{
  lib,
  cluster,
  k8sLib,
  ...
}:
let
  name = "cobblemon";
  namespace = "minecraft";
  labels."app.kubernetes.io/name" = name;

in
{
  imports = [
    (k8sLib.localVolume {
      inherit name namespace;
      node = "r440";
      path = "/var/lib/minecraft/${name}";
      size = "50Gi";
    })
  ];

  resources.core.v1.Service.${name} = {
    metadata = { inherit namespace; };
    metadata.annotations."mc-router.itzg.me/externalServerName" = cluster.minecraft.cobblemon.host;

    spec = {
      selector = labels;
      ports = [
        {
          name = "minecraft";
          port = 25565;
          targetPort = 25565;
        }
      ];
    };
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
        containers = [
          {
            inherit name;
            image = "itzg/minecraft-server:2026.11.1-java21";
            env =
              lib.mapAttrsToList
                (n: v: {
                  name = n;
                  value = v;
                })
                {
                  MOTD = "Neuros.is Cobblemon Server";
                  EULA = "TRUE";
                  MEMORY = "16G";
                  USE_MEOWICE_FLAGS = "TRUE";
                  TYPE = "FABRIC";
                  VERSION = "1.21.1";
                  MODRINTH_PROJECTS = "cobblemon,fabric-api";
                  MODRINTH_DOWNLOAD_DEPENDENCIES = "required";
                };

            ports = [
              {
                name = "minecraft";
                containerPort = 25565;
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

            resources.requests = {
              cpu = "1";
              memory = "16Gi";
            };

            volumeMounts = [
              {
                inherit name;
                mountPath = "/data";
              }
            ];

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
        volumes = [
          {
            name = name;
            persistentVolumeClaim.claimName = name;
          }
        ];
      };
    };
  };

}
