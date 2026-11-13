# The phase-2 export job (docs/pki-migration-plan.md, P2), namespace
# `cluster-pki`: once a day it copies the host leaves cert-manager issued
# here into git as secrets/pki/<node>.yaml (certs plaintext, keys
# sops-encrypted to the admins and that host) and opens a PR. Merging stays
# a human step. The script is pkgs/pki-export/pki-export.sh.
#
# Imported by ./default.nix (component `infra/cluster-pki`, applied by
# `flux-system`; nothing here goes through cert-manager's webhook). The
# namespace comes from ./settings.nix, the Secret names from
# ./leaves.nix (the same set issuers.nix makes Certificates for).
#
#   ServiceAccount pki-export
#   Role/RoleBinding pki-export   `get` on Secrets, limited by resourceNames
#                  to the leaf Secrets below. RBAC cannot select by label,
#                  and `list` cannot be limited by name, so the job does not
#                  list: it gets each leaf by name (PKI_EXPORT_SECRETS). The
#                  CA Secrets (k8s-ca, etcd-ca, front-proxy-ca: intermediate
#                  keys) in the same namespace stay unreadable to it.
#   CronJob pki-export            daily; non-root, read-only root fs, no
#                  capabilities; /tmp is a memory-backed emptyDir (the
#                  leaf keys pass through it in plaintext before sops
#                  encrypts them).
#
# The GitHub credential is the Secret `cluster-pki/pki-export-github`, key
# `token`, from k8s/secrets/cluster-pki/pki-export-github.sops.yaml. Not in
# git yet; to create it (an admin, with the YubiKey):
#
#   1. GitHub > Settings > Developer settings > Fine-grained tokens:
#      resource owner charlie-horse, "Only select repositories":
#      charlie-horse/flake; permissions Contents: Read and write, Pull
#      requests: Read and write (Metadata: read is implied); nothing else.
#      Expiry at most a year (put a reminder in docs/cluster.md).
#   2. In the repo, from the dev shell (never paste the token on a command
#      line; `sops` opens $EDITOR):
#        sops k8s/secrets/cluster-pki/pki-export-github.sops.yaml
#      with the content
#        apiVersion: v1
#        kind: Secret
#        metadata:
#          name: pki-export-github
#          namespace: cluster-pki
#        type: Opaque
#        stringData:
#          token: <the token>
#      (the k8s/secrets rule in .sops.yaml encrypts stringData to the admins
#      + flux). Add a row for it to docs/cluster.md, "Secrets (all of them)".
#   3. PR, merge; the Flux Kustomization `secrets` creates it.
#
# The image is pkgs/pki-export's `image` (flake output
# packages.x86_64-linux.pki-export-image), pushed to
# ghcr.io/charlie-horse/flake/pki-export by
# .github/workflows/pki-export-image.yml. It is amd64 only, so the job runs
# on amd64 nodes (k8s/render.nix exempts it from the multi-arch check).
# Until `digest` below is set from that workflow's output, the CronJob is
# suspended.
{ lib, cluster, ... }:
let
  inherit (import ./settings.nix) namespace;
  name = "pki-export";

  # sha256 digest printed by .github/workflows/pki-export-image.yml on main
  # ("sha256:..."). null: CronJob suspended. Pin it after the token Secret
  # exists and the Issuers are Ready (P6).
  digest = null;
  imageRepo = "ghcr.io/charlie-horse/flake/pki-export";
  image = if digest == null then "${imageRepo}:main" else "${imageRepo}@${digest}";

  # Every leaf Secret (== Certificate name, <component>-<node>).
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
