# cloudflared + nginx sidecar, one replica per node (required pod
# anti-affinity, every node's taints tolerated), so the tunnel has a
# connector on every node and keeps serving while any node is down;
# Cloudflare balances between the connectors.
#
# hostNetwork, on purpose: the nginx sidecar's connections to the ClusterIPs
# then leave from the node's own addresses (kube-proxy picks cni0 10.244.N.1
# or flannel.1 10.244.N.0 as source), and authentik trusts X-Forwarded-*
# only from those (apps/authentik/chart.nix). An ordinary pod (10.244.N.2
# and up) can therefore not forge a client IP. Both containers listen on
# loopback only (nginx 9190, cloudflared's metrics 20250), so nothing is
# exposed on the nodes.
{
  lib,
  cluster,
  k8sLib,
  ...
}:
let
  namespace = "cloudflared";
  name = "cloudflared";
  labels."app.kubernetes.io/name" = "cloudflared";
  files = import ./files.nix { inherit lib cluster; };

  containerSecurity = {
    allowPrivilegeEscalation = false;
    readOnlyRootFilesystem = true;
    runAsNonRoot = true;
    capabilities.drop = [ "ALL" ];
  };
in
{
  resources.apps.v1.Deployment.${name} = {
    metadata = { inherit namespace labels; };
    spec = {
      replicas = lib.length (lib.attrNames cluster.nodes);
      selector.matchLabels = labels;
      # hostNetwork + fixed loopback ports: never two on one node, so replace
      # one at a time instead of surging.
      strategy = {
        type = "RollingUpdate";
        rollingUpdate = {
          maxSurge = 0;
          maxUnavailable = 1;
        };
      };
      template = {
        metadata = {
          inherit labels;
          # Roll the pods when the routes or nginx config change.
          annotations."cluster/config-hash" = builtins.hashString "sha256" (files.cloudflared + files.nginx);
        };
        spec = {
          hostNetwork = true;
          dnsPolicy = "ClusterFirstWithHostNet";
          tolerations = k8sLib.nodeTolerations;
          affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution = [
            {
              topologyKey = "kubernetes.io/hostname";
              labelSelector.matchLabels = labels;
            }
          ];
          securityContext = {
            seccompProfile.type = "RuntimeDefault";
            # cloudflared runs as 65532 (nonroot); the Secret is group-readable.
            fsGroup = 65532;
          };
          terminationGracePeriodSeconds = 30;
          containers = [
            {
              name = "cloudflared";
              image = "docker.io/cloudflare/cloudflared:2026.10.3";
              args = [
                "tunnel"
                "--config"
                "/etc/cloudflared/config/config.yaml"
                "run"
              ];
              securityContext = containerSecurity // {
                runAsUser = 65532;
                runAsGroup = 65532;
              };
              # hostNetwork: probe the node's loopback, where it listens.
              readinessProbe.httpGet = {
                host = "127.0.0.1";
                port = files.metricsPort;
                path = "/ready";
              };
              livenessProbe = {
                httpGet = {
                  host = "127.0.0.1";
                  port = files.metricsPort;
                  path = "/ready";
                };
                initialDelaySeconds = 30;
                periodSeconds = 20;
                failureThreshold = 6;
              };
              resources = {
                requests = {
                  cpu = "20m";
                  memory = "64Mi";
                };
                limits.memory = "256Mi";
              };
              volumeMounts = [
                {
                  name = "config";
                  mountPath = "/etc/cloudflared/config";
                  readOnly = true;
                }
                {
                  name = "credentials";
                  mountPath = "/etc/cloudflared/credentials";
                  readOnly = true;
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
              securityContext = containerSecurity // {
                runAsUser = 101;
                runAsGroup = 101;
              };
              readinessProbe.tcpSocket = {
                host = "127.0.0.1";
                port = files.proxyPort;
              };
              livenessProbe = {
                tcpSocket = {
                  host = "127.0.0.1";
                  port = files.proxyPort;
                };
                periodSeconds = 20;
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
                  name = "config";
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
              name = "config";
              configMap.name = name;
            }
            {
              name = "credentials";
              secret = {
                secretName = "tunnel-credentials";
                defaultMode = 288; # 0440
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
}
