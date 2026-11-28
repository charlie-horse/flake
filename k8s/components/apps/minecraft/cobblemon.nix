{
  lib,
  cluster,
  ...
}:
rec {
  name = "cobblemon";
  image = "itzg/minecraft-server:2026.11.1-java21";
  env = lib.mapAttrsToList (n: v: {
    name = n;
    value = v;
  }) {
    EULA = "TRUE";
    MEMORY = "16G";
    TYPE = "FABRIC";
    VERSION = "1.21.1";
    SERVER_PORT = builtins.toString cluster.minecraft.cobblemon.port;
    MODRINTH_PROJECTS = "cobblemon,fabric-api";
    MODRINTH_DOWNLOAD_DEPENDENCIES = "required";
  };

  ports = [
    {
      name = "minecraft";
      containerPort = cluster.minecraft.cobblemon.port;
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

  resources = {
    requests = {
      cpu = "250m";
      memory = "8Gi";
    };
    limits.memory = "50Gi";
  };

  volumeMounts = [
    {
      inherit name;
      mountPath = "/data";
    }
  ];
}
