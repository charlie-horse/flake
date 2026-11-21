# Dynamic DNS, in namespace `cert-manager`: a CronJob that keeps the DNS-only
# (unproxied) Cloudflare A records `records` in `zone` on the network's
# public IPv4 (ddns.py, from Cloudflare's /cdn-cgi/trace). Every other public
# hostname is a proxied tunnel route (apps/cloudflared), not managed here.
#
# Token: the ACME issuers' Secret cert-manager/cloudflare-api-token (sops,
# key api-token), so one file holds it. The namespace enforces `restricted`.
# Docs: docs/k8s/apps.md#dynamic-dns
{ lib, ... }:
let
  inherit (import ../../infra/cert-manager/settings.nix)
    namespace
    acmeZone
    cloudflareTokenSecret
    cloudflareTokenKey
    ;
  name = "ddns";
  zone = acmeZone;
  records = [ "*.at.neuros.is" ];
  labels."app.kubernetes.io/name" = name;
in
{
  validation.strict = true;

  resources.core.v1 = {
    ConfigMap.${name} = {
      metadata = { inherit namespace labels; };
      data."ddns.py" = builtins.readFile ./ddns.py;
    };
  };

  resources.batch.v1.CronJob.${name} = {
    metadata = { inherit namespace labels; };
    spec = {
      schedule = "*/5 * * * *";
      concurrencyPolicy = "Forbid";
      successfulJobsHistoryLimit = 1;
      failedJobsHistoryLimit = 3;
      jobTemplate.spec = {
        backoffLimit = 0;
        activeDeadlineSeconds = 120;
        template = {
          metadata = { inherit labels; };
          spec = {
            restartPolicy = "Never";
            automountServiceAccountToken = false;
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 65534;
              runAsGroup = 65534;
              seccompProfile.type = "RuntimeDefault";
            };
            containers = [
              {
                inherit name;
                image = "docker.io/library/python:3.13.18-alpine3.24";
                command = [
                  "python3"
                  "-I"
                  "/script/ddns.py"
                ];
                env =
                  lib.mapAttrsToList
                    (n: v: {
                      name = n;
                      value = v;
                    })
                    {
                      ZONE = zone;
                      RECORDS = builtins.toJSON records;
                      TTL = "300";
                      TOKEN_FILE = "/token/${cloudflareTokenKey}";
                    };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                  capabilities.drop = [ "ALL" ];
                };
                resources = {
                  requests = {
                    cpu = "10m";
                    memory = "32Mi";
                  };
                  limits.memory = "64Mi";
                };
                volumeMounts = [
                  {
                    name = "script";
                    mountPath = "/script";
                    readOnly = true;
                  }
                  {
                    name = "token";
                    mountPath = "/token";
                    readOnly = true;
                  }
                ];
              }
            ];
            volumes = [
              {
                name = "script";
                configMap.name = name;
              }
              {
                name = "token";
                secret.secretName = cloudflareTokenSecret;
              }
            ];
          };
        };
      };
    };
  };
}
