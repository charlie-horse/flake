# Daily `pg_dump -Fc` of authentik's database to r440 (hostPath PV
# /var/lib/authentik/backup; the PV's node affinity puts the job there).
# Keeps the newest 14 dumps.
{ k8sLib, ... }:
let
  inherit (import ./settings.nix) namespace db backupName;
in
{
  imports = [
    (k8sLib.localVolume {
      inherit namespace;
      name = backupName;
      node = "r440";
      path = "/var/lib/authentik/backup";
      size = "20Gi";
    })
  ];

  resources.batch.v1.CronJob.${backupName} = {
    metadata = { inherit namespace; };
    spec = {
      schedule = "17 3 * * *";
      timeZone = "America/New_York";
      concurrencyPolicy = "Forbid";
      successfulJobsHistoryLimit = 3;
      failedJobsHistoryLimit = 3;
      jobTemplate.spec = {
        backoffLimit = 2;
        template.spec = {
          restartPolicy = "OnFailure";
          securityContext.seccompProfile.type = "RuntimeDefault";
          containers = [
            {
              name = "pg-dump";
              inherit (db) image;
              env = [
                {
                  name = "PGPASSWORD";
                  valueFrom = db.password;
                }
              ];
              command = [
                "/bin/sh"
                "-ec"
                ''
                  f=/backup/authentik-$(date +%Y%m%dT%H%M%S).dump
                  pg_dump -h ${db.name} -U ${db.user} -d ${db.database} -Fc -f "$f.part"
                  mv "$f.part" "$f"
                  ls -1t /backup/authentik-*.dump | tail -n +15 | xargs -r rm --
                  ls -l /backup
                ''
              ];
              securityContext.allowPrivilegeEscalation = false;
              resources = {
                requests = {
                  cpu = "10m";
                  memory = "64Mi";
                };
                limits.memory = "512Mi";
              };
              volumeMounts = [
                {
                  name = "backup";
                  mountPath = "/backup";
                }
              ];
            }
          ];
          volumes = [
            {
              name = "backup";
              persistentVolumeClaim.claimName = backupName;
            }
          ];
        };
      };
    };
  };
}
