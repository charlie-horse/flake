# ATCR hold (blob service with its own embedded PDS, did:web:<atcrHold.host>).
#
#   https://hold.neuros.is (cluster.atcrHold.host) -> cloudflared + nginx
#     (apps/cloudflared) -> Service atcr-hold at the fixed ClusterIP
#     cluster.atcrHold.serviceIP -> nginx sidecar :8081
#       /atcr-blobs/...  -> Garage :3900 (S3, presigned URLs)
#       everything else  -> hold :8080
#
# The hold's S3 endpoint is that public URL, so the presigned URLs it hands
# to the AppView and to docker clients resolve everywhere. The Service
# publishes not-ready pods: the hold reaches Garage through itself.
# Embedded PDS (SQLite, signing key) on r440 at /var/lib/atcr/hold.
{
  lib,
  cluster,
  k8sLib,
  ...
}:
let
  s = import ./settings.nix;
  inherit (s) namespace;
  name = "atcr-hold";
  labels."app.kubernetes.io/name" = name;
  publicUrl = "https://${cluster.atcrHold.host}";
  image = s.images.hold;

  # Captain (admin) of the hold.
  ownerDid = cluster.tranquilPds.adminDid;

  env = {
    HOLD_SERVER_PUBLIC_URL = publicUrl;
    HOLD_SERVER_APPVIEW_DID = "did:web:${cluster.atcr.host}";
    # Pulls need no crew membership; pushes need captain or crew.
    HOLD_SERVER_PUBLIC = "true";
    HOLD_REGISTRATION_OWNER_DID = ownerDid;
    HOLD_REGISTRATION_ALLOW_ALL_CREW = "false";
    HOLD_REGISTRATION_ENABLE_BLUESKY_POSTS = "false";
    HOLD_REGISTRATION_PROFILE_DISPLAY_NAME = "neurosis hold";
    HOLD_DATABASE_PATH = "/var/lib/atcr-hold";
    AWS_REGION = s.garage.region;
    S3_BUCKET = s.bucket;
    S3_ENDPOINT = publicUrl;
  };

  nginxConf = ''
    worker_processes 2;
    pid /tmp/nginx.pid;
    error_log /dev/stderr warn;
    events { worker_connections 1024; }
    http {
      access_log off;
      client_body_temp_path /tmp/client_temp;
      proxy_temp_path /tmp/proxy_temp;
      fastcgi_temp_path /tmp/fastcgi_temp;
      uwsgi_temp_path /tmp/uwsgi_temp;
      scgi_temp_path /tmp/scgi_temp;

      map $http_upgrade $connection_upgrade {
        default upgrade;
        ""      close;
      }

      server {
        listen 8081;
        client_max_body_size 0;
        proxy_http_version 1.1;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        # Host is part of the SigV4 signature: pass it unchanged.
        proxy_set_header Host $host;

        location /${s.bucket} {
          proxy_pass http://${s.garage.name}.${namespace}.svc.cluster.local:${toString s.garage.s3Port};
        }
        location / {
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection $connection_upgrade;
          proxy_pass http://127.0.0.1:8080;
        }
      }
    }
  '';
in
{
  imports = [
    (k8sLib.localVolume {
      inherit namespace name;
      node = "r440";
      path = "/var/lib/atcr/hold";
      size = "5Gi";
    })
  ];

  resources.core.v1.ConfigMap.${name} = {
    metadata = { inherit namespace labels; };
    data."nginx.conf" = nginxConf;
  };

  resources.apps.v1.Deployment.${name} = {
    metadata = { inherit namespace labels; };
    spec = {
      replicas = s.replicas image;
      selector.matchLabels = labels;
      strategy.type = "Recreate";
      template = {
        metadata.labels = labels;
        spec = s.podSpec // {
          initContainers = [ s.chownData ];
          containers = [
            {
              name = "hold";
              image = s.imageRef image;
              env =
                lib.mapAttrsToList (n: v: {
                  name = n;
                  value = v;
                }) env
                ++ s.secretEnv [
                  {
                    env = "AWS_ACCESS_KEY_ID";
                    key = "S3_ACCESS_KEY_ID";
                  }
                  {
                    env = "AWS_SECRET_ACCESS_KEY";
                    key = "S3_SECRET_ACCESS_KEY";
                  }
                ];
              ports = [
                {
                  name = "hold";
                  containerPort = 8080;
                }
              ];
              readinessProbe = {
                httpGet = {
                  path = "/xrpc/_health";
                  port = "hold";
                };
                periodSeconds = 10;
              };
              livenessProbe = {
                httpGet = {
                  path = "/xrpc/_health";
                  port = "hold";
                };
                initialDelaySeconds = 30;
                periodSeconds = 30;
                failureThreshold = 5;
              };
              securityContext = s.containerSecurity;
              resources = {
                requests = {
                  cpu = "50m";
                  memory = "128Mi";
                };
                limits.memory = "1Gi";
              };
              volumeMounts = [
                {
                  name = "data";
                  mountPath = "/var/lib/atcr-hold";
                }
                {
                  name = "tmp";
                  mountPath = "/tmp";
                }
              ];
            }
            {
              name = "nginx";
              image = "docker.io/nginxinc/nginx-unprivileged:1.31.7-alpine";
              # Not the image's entrypoint (it rewrites conf.d); just nginx.
              command = [
                "nginx"
                "-g"
                "daemon off;"
              ];
              ports = [
                {
                  name = "http";
                  containerPort = 8081;
                }
              ];
              readinessProbe.tcpSocket.port = "http";
              livenessProbe = {
                tcpSocket.port = "http";
                periodSeconds = 20;
              };
              securityContext = s.containerSecurity // {
                runAsNonRoot = true;
                runAsUser = 101;
                runAsGroup = 101;
              };
              resources = {
                requests = {
                  cpu = "20m";
                  memory = "32Mi";
                };
                limits.memory = "256Mi";
              };
              volumeMounts = [
                {
                  name = "nginx";
                  mountPath = "/etc/nginx/nginx.conf";
                  subPath = "nginx.conf";
                  readOnly = true;
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
              name = "nginx";
              configMap.name = name;
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
      clusterIP = cluster.atcrHold.serviceIP;
      publishNotReadyAddresses = true;
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
