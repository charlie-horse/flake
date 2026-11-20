# Tranquil PDS (ATProto Personal Data Server), namespace `atproto`.
#
#   https://pds.neuros.is (cluster.tranquilPds.host) and every
#     *.<handleDomain> (handle resolution) -> cloudflared + nginx
#     (apps/cloudflared) -> Service tranquil-pds at the fixed ClusterIP
#     cluster.tranquilPds.serviceIP -> pod :3000
#
# One replica; repos in PostgreSQL (./postgres.nix), blobs on r440 (hostPath
# PV). DIDs are did:plc. Login: password/passkey, or SSO through authentik's
# provider `tranquil-pds` (group `pds-users`); new accounts need an invite
# code either way. Secret atproto/tranquil-pds-secrets (sops), image pull
# Secret atproto/atcr-io-pull (atcr.io).
# Operating it: docs/k8s/apps.md#tranquil-pds
{
  lib,
  cluster,
  k8sLib,
  ...
}:
let
  inherit (import ./settings.nix) namespace secretName db;
  name = "tranquil-pds";
  labels."app.kubernetes.io/name" = name;

  port = 3000;
  # Handles are <name>.<handleDomain>, resolved over HTTPS
  # (/.well-known/atproto-did), so *.<handleDomain> must reach this Service.
  inherit (cluster.tranquilPds) handleDomain;
  issuer = "https://${cluster.authentik.host}/application/o/tranquil-pds/";

  env = {
    PDS_HOSTNAME = cluster.tranquilPds.host;
    SERVER_HOST = "0.0.0.0";
    SERVER_PORT = toString port;
    PDS_USER_HANDLE_DOMAINS = handleDomain;
    ENABLE_CADDY_ON_DEMAND_TLS = "false";
    INVITE_CODE_REQUIRED = "true";
    # No mail/Discord/Telegram/Signal is configured, so no channel can be
    # verified; without this, unverified accounts can neither log in nor write.
    DISABLE_ACCOUNT_VERIFICATION_GATE = "true";

    REPO_BACKEND = "postgres";
    DATABASE_URL = "postgres://${db.user}:$(POSTGRES_PASSWORD)@${db.name}:5432/${db.database}";
    DATABASE_MAX_CONNECTIONS = "20";
    DATABASE_MIN_CONNECTIONS = "2";
    BLOB_STORAGE_BACKEND = "filesystem";
    BLOB_STORAGE_PATH = "/var/lib/tranquil-pds/blobs";

    SSO_OIDC_ENABLED = "true";
    SSO_OIDC_CLIENT_ID = "tranquil-pds";
    SSO_OIDC_ISSUER = issuer;
    SSO_OIDC_DISPLAY_NAME = "authentik";
  };

  secretEnv = [
    "JWT_SECRET"
    "DPOP_SECRET"
    "MASTER_KEY"
    "SSO_OIDC_CLIENT_SECRET"
  ];

  probe = path: {
    httpGet = {
      inherit path;
      port = "http";
    };
  };
in
{
  imports = [
    ./postgres.nix
    (k8sLib.localVolume {
      inherit namespace name;
      node = "r440";
      path = "/var/lib/tranquil-pds/data";
      size = "50Gi";
    })
  ];

  validation.strict = true;

  resources.apps.v1.Deployment.${name} = {
    metadata = { inherit namespace labels; };
    spec = {
      replicas = 1;
      selector.matchLabels = labels;
      strategy.type = "Recreate";
      template = {
        metadata.labels = labels;
        spec = {
          # The image is linux/amd64 only.
          nodeSelector."kubernetes.io/arch" = "amd64";
          imagePullSecrets = [ { name = "atcr-io-pull"; } ];
          securityContext = {
            seccompProfile.type = "RuntimeDefault";
            runAsNonRoot = true;
            runAsUser = 65532;
            runAsGroup = 65532;
          };
          # The hostPath directory is created root-owned.
          initContainers = [
            {
              name = "chown";
              image = "docker.io/library/busybox:1.37.0";
              command = [
                "chown"
                "65532:65532"
                "/data"
              ];
              securityContext = {
                runAsNonRoot = false;
                runAsUser = 0;
                allowPrivilegeEscalation = false;
                capabilities = {
                  drop = [ "ALL" ];
                  add = [ "CHOWN" ];
                };
              };
              volumeMounts = [
                {
                  name = "data";
                  mountPath = "/data";
                }
              ];
            }
          ];
          containers = [
            {
              inherit name;
              # v0.8.0 (upstream publishes images by commit only).
              image = "atcr.io/tranquil.farm/tranquil-pds:ce17e8a4948aa216c6c1056122966a11b8a693c8";
              env = [
                {
                  name = "POSTGRES_PASSWORD";
                  valueFrom.secretKeyRef = {
                    name = secretName;
                    key = "POSTGRES_PASSWORD";
                  };
                }
              ]
              ++ lib.mapAttrsToList (n: v: {
                name = n;
                value = v;
              }) env
              ++ map (key: {
                name = key;
                valueFrom.secretKeyRef = {
                  name = secretName;
                  inherit key;
                };
              }) secretEnv;
              ports = [
                {
                  name = "http";
                  containerPort = port;
                }
              ];
              startupProbe = probe "/xrpc/_health" // {
                periodSeconds = 5;
                failureThreshold = 60;
              };
              readinessProbe = probe "/xrpc/_health" // {
                periodSeconds = 10;
              };
              livenessProbe = probe "/xrpc/_health" // {
                periodSeconds = 30;
                failureThreshold = 5;
              };
              securityContext = {
                allowPrivilegeEscalation = false;
                capabilities.drop = [ "ALL" ];
              };
              resources = {
                requests = {
                  cpu = "100m";
                  memory = "256Mi";
                };
                limits.memory = "1Gi";
              };
              volumeMounts = [
                {
                  name = "data";
                  mountPath = "/var/lib/tranquil-pds/blobs";
                }
              ];
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
      clusterIP = cluster.tranquilPds.serviceIP;
      selector = labels;
      ports = [
        {
          name = "http";
          port = 80;
          targetPort = "http";
        }
      ];
    };
  };
}
