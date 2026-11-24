# Tangled knot (git server of the Tangled forge, Rust `knot-server`),
# namespace `atproto`. The web UI is the hosted appview tangled.org.
#
#   https://<cluster.tangledKnot.host> -> cloudflared + nginx
#     (apps/cloudflared) -> Service tangled-knot at the fixed ClusterIP
#     cluster.tangledKnot.serviceIP :80 -> pod :5555 (XRPC, smart HTTP, LFS)
#   git over SSH: the same Service :22 -> pod :2222 (not public)
#
# One replica, state in a node-local volume (/data): repos/, lfs/,
# sealed-keys, ssh_host_key. Secret atproto/tangled-knot-secrets (sops:
# KNOT_MASTER_KEY, unseals sealed-keys). Image: pkgs/atproto-images/
# tangled-knot.nix, pushed to GHCR by .github/workflows/atproto-images.yml;
# replicas 0 while digest is null.
# Operation: docs/k8s/apps.md#atproto-services
{
  lib,
  cluster,
  k8sLib,
  ...
}:
let
  namespace = "atproto";
  name = "tangled-knot";
  labels."app.kubernetes.io/name" = name;
  secretName = "tangled-knot-secrets";

  # From .github/workflows/atproto-images.yml on main.
  digest = "sha256:f5c37644269f7dad776b1d1b63eddab144e7e2efbea2b436a8ea30e86a90e386";
  imageRepo = "ghcr.io/charlie-horse/flake/tangled-knot";
  image = if digest == null then "${imageRepo}:main" else "${imageRepo}@${digest}";
  uid = 1000; # the image's User

  # Knot admins; the first is the knot's owner.
  ownerDid = cluster.tranquilPds.adminDid;
  # Served publicly by describeKnot.
  contactEmail = "charliesyvertsen06@icloud.com";

  env = {
    KNOT_HOSTNAME = cluster.tangledKnot.host;
    KNOT_ADMINS = ownerDid;
    KNOT_CONTACT_EMAIL = contactEmail;
    # Fixed per repo at creation; must stay sha1 to interoperate with GitHub.
    KNOT_GIT_OBJECT_FORMAT = "sha1";
    # Client IP from nginx (apps/cloudflared, hostNetwork on every node).
    KNOT_XRPC_TRUSTED_PROXY_HEADER = "x-forwarded-for";
    KNOT_XRPC_TRUSTED_PROXIES = lib.concatStringsSep "," (
      [ cluster.podCidr ] ++ map (n: n.lanIP) (lib.attrValues cluster.nodes)
    );
    KNOT_PLC_DIRECTORY = "https://plc.directory";
    KNOT_SCAN_PATH = "/data/repos";
    KNOT_LFS_STORE_PATH = "/data/lfs";
    KNOT_SEALED_KEY_FILE = "/data/sealed-keys";
    KNOT_SSH_HOST_KEY_FILE = "/data/ssh_host_key";
    # Names the variable that holds the master key.
    KNOT_MASTER_KEY_ENV = "KNOT_MASTER_KEY";
  };

  healthProbe = {
    path = "/xrpc/_health";
    port = "http";
  };
in
{
  imports = [
    (k8sLib.localVolume {
      inherit namespace name;
      node = "r440";
      path = "/var/lib/tangled-knot";
      size = "50Gi";
    })
  ];

  validation.strict = true;

  resources.apps.v1.Deployment.${name} = {
    metadata = { inherit namespace labels; };
    spec = {
      replicas = if digest == null then 0 else 1;
      selector.matchLabels = labels;
      strategy.type = "Recreate";
      template = {
        metadata.labels = labels;
        spec = {
          securityContext.seccompProfile.type = "RuntimeDefault";
          # CI builds the image for x86_64 only.
          nodeSelector."kubernetes.io/arch" = "amd64";
          # The knot drains for up to 40 s on SIGTERM.
          terminationGracePeriodSeconds = 60;
          # The knot does not create its scan path or LFS store.
          initContainers = [
            {
              name = "init-data";
              image = "docker.io/library/busybox:1.37.0";
              command = [
                "sh"
                "-c"
                "mkdir -p /data/repos /data/lfs && chown ${toString uid}:${toString uid} /data /data/repos /data/lfs"
              ];
              securityContext = {
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
              name = "knot";
              inherit image;
              env =
                lib.mapAttrsToList (n: v: {
                  name = n;
                  value = v;
                }) env
                ++ [
                  {
                    name = "KNOT_MASTER_KEY";
                    valueFrom.secretKeyRef = {
                      name = secretName;
                      key = "KNOT_MASTER_KEY";
                    };
                  }
                ];
              ports = [
                {
                  name = "http";
                  containerPort = 5555;
                }
                {
                  name = "ssh";
                  containerPort = 2222;
                }
              ];
              startupProbe = {
                httpGet = healthProbe;
                periodSeconds = 10;
                failureThreshold = 60;
              };
              readinessProbe = {
                httpGet = healthProbe;
                periodSeconds = 10;
              };
              livenessProbe = {
                httpGet = healthProbe;
                periodSeconds = 30;
                failureThreshold = 5;
              };
              securityContext = {
                runAsUser = uid;
                runAsGroup = uid;
                runAsNonRoot = true;
                allowPrivilegeEscalation = false;
                capabilities.drop = [ "ALL" ];
              };
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
                  mountPath = "/data";
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
      clusterIP = cluster.tangledKnot.serviceIP;
      selector = labels;
      ports = [
        {
          name = "http";
          port = 80;
          targetPort = "http";
        }
        {
          name = "ssh";
          port = 22;
          targetPort = "ssh";
        }
      ];
    };
  };
}
