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
  rconPort = 25575;

  env = {
    EULA = "TRUE";
    TYPE = "FORGE";
    VERSION = "1.21.1"
  };

  probe = {
    command = "mc-health";
    initialDelaySeconds = 30;
    periodSeconds = 5;
    failureThreshold = 20;
    successThreshold = 1;
    timeoutSeconds = 1;
  }

  cobblemonContainer = {
    inherit name;
    image = "itzg/minecraft-server:java25";
    env =
      lib.mapAttrsToList (n: v: {
        name = n;
        value = v;
      }) env;

    ports = [
      {
        name = "minecraft";
        containerPort = mcPort;
      }
    ];

    startupProbe.enabled = false;
    readinessProbe = probe;
    livenessProbe = probe;

    securityContext = {
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
  }
in
{
  imports = [
    (k8sLib.localVolume {
      inherit namespace name;
      node = "r440";
      path = "/var/lib/minecraft/cobblemon/";
      size = "50Gi";
    })
  ];

  validation.strict = true;

  resources.apps.v1.Deployment.${name} = {
    replicas = 1;
    metadata = { inherit namespace labels; };

    template.metadata = { inherit labels; };
    template.spec = {
      containers = [cobblemonContainer];
      volumes = [
        {
          name = "data";
          persistentVolumeClaim.claimName = name;
        }
      ]
    }
  };

  resources.core.v1.Service.${name} = {
    metadata = { inherit namespace labels; };
    spec = {
      clusterIP = cluster.cobblemon.serviceIP;
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
}
