# podinfo smoke app (namespace podinfo): three replicas spread one per
# node (topologySpreadConstraints on kubernetes.io/hostname), so the arm64
# worker (m2mini) runs one too; the image is a manifest list with
# linux/amd64 and linux/arm64 (checked by `nix run .#k8s-check-images`).
#
#   kubectl -n podinfo get pods -o wide
#   kubectl -n podinfo run curl --rm -it --restart=Never \
#     --image=curlimages/curl -- curl -s podinfo.podinfo:9898
#
# Each replica reports its node's architecture in `runtime` / `arch`.
let
  namespace = "podinfo";
  labels."app.kubernetes.io/name" = "podinfo";
  image = "ghcr.io/stefanprodan/podinfo:6.17.0";
in
{
  validation.strict = true;

  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "restricted";
  };

  resources.apps.v1.Deployment.podinfo = {
    metadata = { inherit namespace labels; };
    spec = {
      replicas = 3;
      selector.matchLabels = labels;
      template = {
        metadata = { inherit labels; };
        spec = {
          topologySpreadConstraints = [
            {
              maxSkew = 1;
              topologyKey = "kubernetes.io/hostname";
              whenUnsatisfiable = "ScheduleAnyway";
              labelSelector.matchLabels = labels;
            }
          ];
          securityContext = {
            runAsNonRoot = true;
            runAsUser = 100;
            seccompProfile.type = "RuntimeDefault";
          };
          containers = [
            {
              name = "podinfo";
              inherit image;
              command = [
                "./podinfo"
                "--port=9898"
                "--level=info"
              ];
              env = [
                {
                  name = "PODINFO_UI_MESSAGE";
                  value = "solaris smoke test";
                }
              ];
              ports = [
                {
                  name = "http";
                  containerPort = 9898;
                }
              ];
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
                limits.memory = "128Mi";
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
                  path = "/healthz";
                  port = "http";
                };
                initialDelaySeconds = 5;
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
              emptyDir = { };
            }
          ];
        };
      };
    };
  };

  resources.core.v1.Service.podinfo = {
    metadata = { inherit namespace labels; };
    spec = {
      selector = labels;
      ports = [
        {
          name = "http";
          port = 9898;
          targetPort = "http";
        }
      ];
    };
  };
}
