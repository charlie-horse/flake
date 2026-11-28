{
  lib,
  cluster,
  k8sLib,
  ...
}:
let
  namespace = "minecraft";
  labels."app.kubernetes.io/name" = namespace;

  mcPort = 25565;

  securityContext = {
    runAsNonRoot = true;
    runAsUser = 1000;
    runAsGroup = 1000;
    seccompProfile.type = "RuntimeDefault";
    allowPrivilegeEscalation = false;
    capabilities.drop = [ "ALL" ];
  };

  servers = map (server: server { inherit lib cluster; }) [ (import ./cobblemon.nix) ];
in
{
  imports =
    [ ]
    ++ map (
      server:
      (k8sLib.localVolume {
        inherit (server) name;
        inherit namespace;
        node = "r440";
        path = "/var/lib/minecraft/${server.name}";
        size = "20Gi";
      })
    ) servers;

  validation.strict = true;

  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "privileged";
  };

  resources.apps.v1.Deployment.minecraft = {
    metadata = { inherit namespace labels; };

    spec = {
      replicas = 1;
      strategy.type = "Recreate";
      selector.matchLabels = labels;

      template.metadata = { inherit labels; };
      template.spec = {
        nodeSelector."kubernetes.io/hostname" = "r440";
        containers =
          map (container: container // { inherit securityContext; }) [
            {
              name = "router";
              image = "itzg/mc-router:1.57.1";

              env = [
                {
                  name = "MAPPING";
                  value = ''
                    
                                      ${cluster.minecraft.cobblemon.host}=localhost:${builtins.toString cluster.minecraft.cobblemon.port}
                  '';
                }
              ];

              ports = [
                {
                  name = "minecraft";
                  containerPort = mcPort;
                  hostPort = mcPort;
                  hostIP = cluster.nodes.r440.lanIP;
                }
              ];
            }
          ]
          ++ servers;

        volumes = map (server: {
          inherit (server) name;
          persistentVolumeClaim.claimName = server.name;
        }) servers;
      };
    };
  };
}
