# PostgreSQL for Tranquil PDS: a plain StatefulSet (official image), single
# instance, data on r440 (hostPath PV /var/lib/tranquil-pds/postgres).
#
# The image's entrypoint starts as root, creates and chowns PGDATA (default
# /var/lib/postgresql/18/docker, under the mount) and drops to the postgres
# user, so this pod is `baseline`, not `restricted`.
{ k8sLib, ... }:
let
  inherit (import ./settings.nix) namespace db;
  pgIsReady = [
    "pg_isready"
    "-U"
    db.user
    "-d"
    db.database
  ];
in
{
  imports = [
    (k8sLib.localVolume {
      inherit namespace;
      name = db.name;
      node = "r440";
      path = "/var/lib/tranquil-pds/postgres";
      size = "10Gi";
    })
  ];

  resources.apps.v1.StatefulSet.${db.name} = {
    metadata = {
      inherit namespace;
      labels = db.labels;
    };
    spec = {
      serviceName = db.name;
      replicas = 1;
      selector.matchLabels = db.labels;
      template = {
        metadata.labels = db.labels;
        spec = {
          securityContext.seccompProfile.type = "RuntimeDefault";
          terminationGracePeriodSeconds = 60;
          containers = [
            {
              name = "postgresql";
              inherit (db) image;
              env = [
                {
                  name = "POSTGRES_DB";
                  value = db.database;
                }
                {
                  name = "POSTGRES_USER";
                  value = db.user;
                }
                {
                  name = "POSTGRES_PASSWORD";
                  valueFrom = db.password;
                }
              ];
              ports = [
                {
                  name = "postgresql";
                  containerPort = 5432;
                }
              ];
              readinessProbe = {
                exec.command = pgIsReady;
                periodSeconds = 10;
              };
              livenessProbe = {
                exec.command = pgIsReady;
                initialDelaySeconds = 30;
                periodSeconds = 20;
                failureThreshold = 6;
              };
              securityContext.allowPrivilegeEscalation = false;
              resources = {
                requests = {
                  cpu = "50m";
                  memory = "256Mi";
                };
                limits.memory = "1Gi";
              };
              volumeMounts = [
                {
                  name = "data";
                  mountPath = "/var/lib/postgresql";
                }
                {
                  name = "shm";
                  mountPath = "/dev/shm";
                }
              ];
            }
          ];
          volumes = [
            {
              name = "data";
              persistentVolumeClaim.claimName = db.name;
            }
            {
              name = "shm";
              emptyDir = {
                medium = "Memory";
                sizeLimit = "256Mi";
              };
            }
          ];
        };
      };
    };
  };

  resources.core.v1.Service.${db.name} = {
    metadata = {
      inherit namespace;
      labels = db.labels;
    };
    spec = {
      selector = db.labels;
      ports = [
        {
          name = "postgresql";
          port = 5432;
          targetPort = "postgresql";
        }
      ];
    };
  };
}
