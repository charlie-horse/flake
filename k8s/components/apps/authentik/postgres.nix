# PostgreSQL for authentik: a plain StatefulSet (official postgres image,
# not the chart's bundled subchart), single instance, data on m2mini's NVMe
# (hostPath PV /var/lib/authentik/postgres). r440's root is the 5400 rpm HDD
# that already slows its etcd WAL.
#
# The image's entrypoint starts as root, chowns PGDATA and drops to the
# postgres user (gosu), so this pod is `baseline`, not `restricted`. PGDATA
# is a subdirectory: the mount point itself is created root-owned by the
# kubelet.
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
      node = "m2mini";
      path = "/var/lib/authentik/postgres";
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
                {
                  name = "PGDATA";
                  value = "/var/lib/postgresql/data/pgdata";
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
                  mountPath = "/var/lib/postgresql/data";
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
