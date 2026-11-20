# Garage: single-node S3 store for the hold's blobs (bucket `atcr-blobs`).
# `--single-node --default-bucket` makes the layout, the access key
# (S3_ACCESS_KEY_ID/S3_SECRET_ACCESS_KEY from the Secret) and the bucket at
# start; capacity is the size of r440's root filesystem. Reached in the
# cluster at atcr-garage:3900 and publicly as https://<atcrHold.host>/atcr-blobs/
# through the hold pod's nginx (hold.nix).
{ k8sLib, ... }:
let
  s = import ./settings.nix;
  inherit (s) namespace garage;
  inherit (garage) name;
  labels."app.kubernetes.io/name" = name;

  config = ''
    replication_factor = 1
    metadata_dir = "/var/lib/garage/meta"
    data_dir = "/var/lib/garage/data"
    metadata_auto_snapshot_interval = "6h"
    rpc_bind_addr = "0.0.0.0:3901"
    rpc_public_addr = "127.0.0.1:3901"

    [s3_api]
    api_bind_addr = "0.0.0.0:${toString garage.s3Port}"
    s3_region = "${garage.region}"

    [admin]
    api_bind_addr = "0.0.0.0:3903"
  '';
in
{
  imports = [
    (k8sLib.localVolume {
      inherit namespace name;
      node = "r440";
      path = "/var/lib/atcr/garage";
      size = "200Gi";
    })
  ];

  resources.core.v1.ConfigMap.${name} = {
    metadata = { inherit namespace labels; };
    data."garage.toml" = config;
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
          containers = [
            {
              name = "garage";
              inherit (garage) image;
              command = [
                "/garage"
                "server"
                "--single-node"
                "--default-bucket"
              ];
              env = [
                {
                  name = "GARAGE_DEFAULT_BUCKET";
                  value = s.bucket;
                }
              ]
              ++ s.secretEnv [
                {
                  env = "GARAGE_RPC_SECRET";
                  key = "GARAGE_RPC_SECRET";
                }
                {
                  env = "GARAGE_DEFAULT_ACCESS_KEY";
                  key = "S3_ACCESS_KEY_ID";
                }
                {
                  env = "GARAGE_DEFAULT_SECRET_KEY";
                  key = "S3_SECRET_ACCESS_KEY";
                }
              ];
              ports = [
                {
                  name = "s3";
                  containerPort = garage.s3Port;
                }
                {
                  name = "admin";
                  containerPort = 3903;
                }
              ];
              readinessProbe = {
                httpGet = {
                  path = "/health";
                  port = "admin";
                };
                periodSeconds = 10;
              };
              livenessProbe = {
                tcpSocket.port = "s3";
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
                  name = "config";
                  mountPath = "/etc/garage.toml";
                  subPath = "garage.toml";
                  readOnly = true;
                }
                {
                  name = "data";
                  mountPath = "/var/lib/garage";
                }
              ];
            }
          ];
          volumes = [
            {
              name = "config";
              configMap.name = name;
            }
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
          name = "s3";
          port = garage.s3Port;
          targetPort = "s3";
        }
      ];
    };
  };
}
