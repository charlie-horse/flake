# ATCR AppView: OCI distribution API and web UI, did:web:<atcr.host>.
#
#   https://cr.neuros.is (cluster.atcr.host) -> cloudflared + nginx
#     (apps/cloudflared) -> Service atcr-appview at the fixed ClusterIP
#     cluster.atcr.serviceIP -> pod :5000
#
# Manifests go to each user's own PDS; blobs to the default hold
# (did:web:<atcrHold.host>). Pushed layers stream through this pod in 10 MB
# parts to the hold's presigned S3 URLs; pulls are redirected to them.
# SQLite (OAuth sessions, JWT and OAuth keys) on r440 at /var/lib/atcr/appview.
{
  lib,
  cluster,
  k8sLib,
  ...
}:
let
  s = import ./settings.nix;
  inherit (s) namespace;
  name = "atcr-appview";
  labels."app.kubernetes.io/name" = name;
  port = 5000;
  image = s.images.appview;

  env = {
    ATCR_SERVER_BASE_URL = "https://${cluster.atcr.host}";
    ATCR_SERVER_DEFAULT_HOLD_DID = "did:web:${cluster.atcrHold.host}";
    ATCR_SERVER_CLIENT_NAME = "neurosis container registry";
    ATCR_SERVER_CLIENT_SHORT_NAME = "neurosis cr";
    ATCR_UI_DATABASE_PATH = "/var/lib/atcr/ui.db";
  };
in
{
  imports = [
    (k8sLib.localVolume {
      inherit namespace name;
      node = "r440";
      path = "/var/lib/atcr/appview";
      size = "5Gi";
    })
  ];

  resources.apps.v1.Deployment.${name} = {
    metadata = { inherit namespace labels; };
    spec = {
      replicas = s.replicas image;
      selector.matchLabels = labels;
      strategy.type = "Recreate";
      template = {
        metadata.labels = labels;
        spec = s.podSpec // {
          imagePullSecrets = k8sLib.flakeImages.pullSecrets;
          initContainers = [ s.chownData ];
          containers = [
            {
              name = "appview";
              image = k8sLib.flakeImages.ref image.name image.digest;
              env = lib.mapAttrsToList (n: v: {
                name = n;
                value = v;
              }) env;
              ports = [
                {
                  name = "http";
                  containerPort = port;
                }
              ];
              readinessProbe = {
                httpGet = {
                  path = "/health";
                  port = "http";
                };
                periodSeconds = 10;
              };
              livenessProbe = {
                httpGet = {
                  path = "/health";
                  port = "http";
                };
                initialDelaySeconds = 30;
                periodSeconds = 30;
                failureThreshold = 5;
              };
              securityContext = s.containerSecurity;
              resources = {
                requests = {
                  cpu = "100m";
                  memory = "256Mi";
                };
                limits.memory = "2Gi";
              };
              volumeMounts = [
                {
                  name = "data";
                  mountPath = "/var/lib/atcr";
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
              name = "data";
              persistentVolumeClaim.claimName = name;
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

  resources.core.v1.Service.${name} = {
    metadata = { inherit namespace labels; };
    spec = {
      clusterIP = cluster.atcr.serviceIP;
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
