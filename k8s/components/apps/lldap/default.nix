# LLDAP (lightweight LDAP user directory), namespace `lldap`.
#
#   Service lldap (ClusterIP): ldap 3890 (plain LDAP, in-cluster only),
#   http 17170 (web UI, reached with kubectl port-forward; no public host)
#   base DN dc=neuros,dc=is; admin uid=admin,ou=people,dc=neuros,dc=is
#
# One replica (SQLite in /data), data on r440 (hostPath PV). The init
# container chowns /data to the image's user (1000), the server runs as it.
# Secret lldap/lldap-secrets (sops: LLDAP_JWT_SECRET, LLDAP_KEY_SEED,
# LLDAP_LDAP_USER_PASS), read at start. Operating it: docs/k8s/apps.md#lldap
{ lib, k8sLib, ... }:
let
  namespace = "lldap";
  name = "lldap";
  labels."app.kubernetes.io/name" = "lldap";
  secretName = "lldap-secrets";
  image = "ghcr.io/lldap/lldap:v0.6.3-alpine-rootless";
  uid = 1000;

  env = {
    TZ = "UTC";
    LLDAP_LDAP_BASE_DN = "dc=neuros,dc=is";
    LLDAP_LDAP_USER_DN = "admin";
    LLDAP_DATABASE_URL = "sqlite:///data/users.db?mode=rwc";
    LLDAP_HTTP_URL = "http://localhost:17170";
  };

  dataMount = {
    name = "data";
    mountPath = "/data";
  };

  httpProbe = {
    httpGet = {
      path = "/health";
      port = "http";
    };
  };
in
{
  imports = [
    (k8sLib.localVolume {
      inherit namespace name;
      node = "r440";
      path = "/var/lib/lldap/data";
      size = "1Gi";
    })
  ];

  validation.strict = true;

  # baseline: the init container runs as root to chown the hostPath volume.
  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "baseline";
    "pod-security.kubernetes.io/warn" = "restricted";
  };

  resources.apps.v1.Deployment.${name} = {
    metadata = { inherit namespace labels; };
    spec = {
      replicas = 1;
      selector.matchLabels = labels;
      strategy.type = "Recreate";
      template = {
        metadata.labels = labels;
        spec = {
          securityContext.seccompProfile.type = "RuntimeDefault";
          initContainers = [
            {
              name = "chown-data";
              inherit image;
              command = [
                "chown"
                "${toString uid}:${toString uid}"
                "/data"
              ];
              securityContext = {
                runAsUser = 0;
                allowPrivilegeEscalation = false;
                capabilities = {
                  drop = [ "ALL" ];
                  add = [ "CHOWN" ];
                };
              };
              volumeMounts = [ dataMount ];
            }
          ];
          containers = [
            {
              inherit name image;
              env =
                lib.mapAttrsToList (n: v: {
                  name = n;
                  value = v;
                }) env
                ++
                  map
                    (key: {
                      name = key;
                      valueFrom.secretKeyRef = {
                        name = secretName;
                        inherit key;
                      };
                    })
                    [
                      "LLDAP_JWT_SECRET"
                      "LLDAP_KEY_SEED"
                      "LLDAP_LDAP_USER_PASS"
                    ];
              ports = [
                {
                  name = "ldap";
                  containerPort = 3890;
                }
                {
                  name = "http";
                  containerPort = 17170;
                }
              ];
              startupProbe = httpProbe // {
                periodSeconds = 5;
                failureThreshold = 60;
              };
              readinessProbe = httpProbe // {
                periodSeconds = 10;
              };
              livenessProbe = {
                tcpSocket.port = "ldap";
                periodSeconds = 30;
                failureThreshold = 5;
              };
              securityContext = {
                runAsNonRoot = true;
                runAsUser = uid;
                runAsGroup = uid;
                allowPrivilegeEscalation = false;
                capabilities.drop = [ "ALL" ];
              };
              resources = {
                requests = {
                  cpu = "50m";
                  memory = "64Mi";
                };
                limits.memory = "256Mi";
              };
              volumeMounts = [ dataMount ];
            }
          ];
          volumes = [
            {
              name = "data";
              persistentVolumeClaim.claimName = name;
            }
          ];
        };
      };
    };
  };

  resources.core.v1.Service.${name} = {
    metadata = { inherit namespace labels; };
    spec = {
      selector = labels;
      ports = [
        {
          name = "ldap";
          port = 3890;
          targetPort = "ldap";
        }
        {
          name = "http";
          port = 17170;
          targetPort = "http";
        }
      ];
    };
  };
}
