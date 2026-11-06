# Zot OCI registry (namespace zot): where CI pushes the signed k8s render
# and what Flux's OCIRepository (50-flux-sync) pulls. One replica pinned to
# r440, data in hostPath /var/lib/zot (created by hosts/r440/zot.nix, owned
# by uid/gid 10500).
#
#   Flux (in cluster)  http://zot.zot.svc.cluster.local:5000  anonymous read
#   CI (over tailnet)  http://r440:30500 (NodePort)           user `ci`
#
# Plain HTTP: tailscale0 encrypts the CI hop and the Flux hop stays on the
# pod network. TLS from the cluster PKI is a follow-up (docs/pki.md).
#
# Not in git (create before Zot starts; the pod waits for it):
#   kubectl -n zot create secret generic zot-htpasswd --from-file=htpasswd=<file>
# where <file> is a bcrypt htpasswd entry for user `ci` (`htpasswd -B -c
# <file> ci`, prompts). The same password goes in the GitHub secret
# ZOT_CI_PASSWORD.
#
# Bootstrap loop: Flux pulls from a registry Flux deploys. A fresh cluster
# applies this file by hand before Flux (k8s/README.md); if Zot is down,
# Flux keeps the last applied state and resumes when Zot is back.
let
  namespace = "zot";
  labels."app.kubernetes.io/name" = "zot";
  image = "ghcr.io/project-zot/zot:v2.1.23";
  uid = 10500; # no user on r440 has it (1000 is a login user)

  config = {
    distSpecVersion = "1.1.1";
    storage = {
      rootDirectory = "/var/lib/registry";
      dedupe = true;
      gc = true;
      gcDelay = "1h";
      gcInterval = "24h";
      retention = {
        delay = "24h";
        policies = [
          {
            repositories = [ "**" ];
            deleteReferrers = false; # keep cosign signatures (OCI referrers)
            deleteUntagged = true;
            keepTags = [
              { patterns = [ "^main$" ]; }
              {
                patterns = [ "^sha-.*" ];
                mostRecentlyPushedCount = 50;
              }
              # cosign signatures stored as tags (sha256-<digest>.sig)
              {
                patterns = [ "^sha256-.*" ];
                mostRecentlyPushedCount = 100;
              }
            ];
          }
        ];
      };
    };
    http = {
      address = "0.0.0.0";
      port = "5000";
      auth.htpasswd.path = "/etc/zot/auth/htpasswd";
      accessControl.repositories."**" = {
        anonymousPolicy = [ "read" ];
        policies = [
          {
            users = [ "ci" ];
            actions = [
              "read"
              "create"
              "update"
              "delete"
            ];
          }
        ];
      };
    };
    log.level = "info";
  };
in
{
  validation.strict = true;

  # Not `enforce: restricted` (as podinfo): the hostPath data volume is
  # forbidden by both restricted and baseline. Everything else complies.
  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/warn" = "restricted";
    "pod-security.kubernetes.io/warn-version" = "latest";
  };

  resources.core.v1.ConfigMap.zot-config = {
    metadata = { inherit namespace labels; };
    data."config.json" = builtins.toJSON config;
  };

  resources.apps.v1.Deployment.zot = {
    metadata = { inherit namespace labels; };
    spec = {
      replicas = 1;
      strategy.type = "Recreate"; # one writer on the hostPath
      selector.matchLabels = labels;
      template = {
        metadata = { inherit labels; };
        spec = {
          nodeSelector."kubernetes.io/hostname" = "r440";
          securityContext = {
            runAsNonRoot = true;
            runAsUser = uid;
            runAsGroup = uid;
            seccompProfile.type = "RuntimeDefault";
          };
          containers = [
            {
              name = "zot";
              inherit image;
              command = [
                "/usr/bin/zot"
                "serve"
                "/etc/zot/config.json"
              ];
              ports = [
                {
                  name = "http";
                  containerPort = 5000;
                }
              ];
              securityContext = {
                allowPrivilegeEscalation = false;
                readOnlyRootFilesystem = true;
                capabilities.drop = [ "ALL" ];
              };
              resources = {
                requests = {
                  cpu = "50m";
                  memory = "128Mi";
                };
                limits.memory = "1Gi";
              };
              readinessProbe = {
                httpGet = {
                  path = "/readyz";
                  port = "http";
                };
                periodSeconds = 5;
              };
              livenessProbe = {
                httpGet = {
                  path = "/livez";
                  port = "http";
                };
                initialDelaySeconds = 10;
              };
              volumeMounts = [
                {
                  name = "config";
                  mountPath = "/etc/zot/config.json";
                  subPath = "config.json";
                  readOnly = true;
                }
                {
                  name = "htpasswd";
                  mountPath = "/etc/zot/auth";
                  readOnly = true;
                }
                {
                  name = "data";
                  mountPath = "/var/lib/registry";
                }
                {
                  name = "tmp";
                  mountPath = "/tmp";
                }
              ];
            }
          ];
          volumes = [
            {
              name = "config";
              configMap.name = "zot-config";
            }
            {
              name = "htpasswd";
              secret.secretName = "zot-htpasswd";
            }
            {
              # Until the FC array or a CSI driver gives us PVs.
              name = "data";
              hostPath = {
                path = "/var/lib/zot";
                type = "Directory";
              };
            }
            {
              name = "tmp";
              emptyDir = { };
            }
          ];
        };
      };
    };
  };

  resources.core.v1.Service.zot = {
    metadata = { inherit namespace labels; };
    spec = {
      type = "NodePort";
      selector = labels;
      ports = [
        {
          name = "http";
          port = 5000;
          targetPort = "http";
          nodePort = 30500;
        }
      ];
    };
  };
}
