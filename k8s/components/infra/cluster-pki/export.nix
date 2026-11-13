# Token, image digest and activation: docs/pki.md, "Phase 2 operations".
{ lib, cluster, ... }:
let
  inherit (import ./settings.nix) namespace;
  name = "pki-export";

  # From .github/workflows/pki-export-image.yml on main; null keeps the CronJob suspended.
  digest = "sha256:f74eab678c8f67e17890646efccaaa13e2352fba17eb1463ba3805f1d8bba4df";
  imageRepo = "ghcr.io/charlie-horse/flake/pki-export";
  image = if digest == null then "${imageRepo}:main" else "${imageRepo}@${digest}";

  leafSecrets = map (l: l.name) (import ./leaves.nix { inherit lib cluster; });

  tokenDir = "/var/run/secrets/pki-export-github";
in
{
  resources.core.v1.ServiceAccount.${name}.metadata = { inherit namespace; };

  resources."rbac.authorization.k8s.io".v1 = {
    Role.${name} = {
      metadata = { inherit namespace; };
      rules = [
        {
          apiGroups = [ "" ];
          resources = [ "secrets" ];
          # No `list`: RBAC can't restrict list by name, and the CA keys share this namespace.
          verbs = [ "get" ];
          resourceNames = leafSecrets;
        }
      ];
    };
    RoleBinding.${name} = {
      metadata = { inherit namespace; };
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        inherit name;
      };
      subjects = [
        {
          kind = "ServiceAccount";
          inherit name namespace;
        }
      ];
    };
  };

  resources.batch.v1.CronJob.${name} = {
    metadata = { inherit namespace; };
    spec = {
      schedule = "41 9 * * *";
      timeZone = "America/New_York";
      suspend = digest == null;
      concurrencyPolicy = "Forbid";
      startingDeadlineSeconds = 3600;
      successfulJobsHistoryLimit = 3;
      failedJobsHistoryLimit = 3;
      jobTemplate.spec = {
        backoffLimit = 1;
        activeDeadlineSeconds = 900;
        ttlSecondsAfterFinished = 604800;
        template.spec = {
          serviceAccountName = name;
          automountServiceAccountToken = true;
          restartPolicy = "Never";
          nodeSelector."kubernetes.io/arch" = "amd64";
          securityContext = {
            runAsNonRoot = true;
            runAsUser = 65532;
            runAsGroup = 65532;
            fsGroup = 65532;
            seccompProfile.type = "RuntimeDefault";
          };
          containers = [
            {
              inherit name image;
              env = [
                {
                  name = "PKI_EXPORT_SECRETS";
                  value = lib.concatStringsSep " " leafSecrets;
                }
                {
                  name = "PKI_EXPORT_TOKEN_FILE";
                  value = "${tokenDir}/token";
                }
                {
                  name = "GITHUB_REPOSITORY";
                  value = "charlie-horse/flake";
                }
              ];
              securityContext = {
                readOnlyRootFilesystem = true;
                allowPrivilegeEscalation = false;
                capabilities.drop = [ "ALL" ];
              };
              resources = {
                requests = {
                  cpu = "10m";
                  memory = "64Mi";
                };
                limits.memory = "256Mi";
              };
              volumeMounts = [
                {
                  name = "tmp";
                  mountPath = "/tmp";
                }
                {
                  name = "github";
                  mountPath = tokenDir;
                  readOnly = true;
                }
              ];
            }
          ];
          volumes = [
            {
              name = "tmp";
              # Leaf keys pass through /tmp in plaintext before sops encrypts them.
              emptyDir = {
                medium = "Memory";
                sizeLimit = "64Mi";
              };
            }
            {
              name = "github";
              secret = {
                secretName = "pki-export-github";
                defaultMode = 288; # 0440: root:65532 (fsGroup)
                items = [
                  {
                    key = "token";
                    path = "token";
                  }
                ];
              };
            }
          ];
        };
      };
    };
  };
}
