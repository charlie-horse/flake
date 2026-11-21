# Public TLS edge for Tranquil PDS handles, namespace `atproto-edge`:
#
#   https://<name>.<handleDomain> -> router TCP 443 -> r440 lanIP:443
#     -> nginx (this DaemonSet, on r440 only, hostPort 443 on its LAN IP)
#     -> http://<tranquilPds.serviceIP>:80
#
# Serves /.well-known/atproto-did and /.well-known/did.json of
# *.<handleDomain> only (nginx.conf). Certificate: Secret at-wildcard-tls,
# from the deferred component apps/atproto-edge-certs (./certificate.nix).
# nginx reloads when the mounted certificate changes. hostPort is why the
# namespace is `privileged`. Docs: docs/k8s/apps.md#atproto-tls-edge
{
  lib,
  cluster,
  k8sLib,
  ...
}:
let
  namespace = "atproto-edge";
  name = "atproto-edge";
  # The router forwards public TCP 443 to this node.
  node = "r440";
  labels."app.kubernetes.io/name" = name;
  port = 8443;
  tlsSecret = "at-wildcard-tls";
  certFile = "/etc/nginx/tls/tls.crt";

  nginxConf =
    lib.replaceStrings
      [
        "@HANDLE_DOMAIN@"
        "@PORT@"
        "@UPSTREAM@"
      ]
      [
        cluster.tranquilPds.handleDomain
        (toString port)
        "${cluster.tranquilPds.serviceIP}:80"
      ]
      (builtins.readFile ./nginx.conf);

  # nginx in the background; every 5 min, reload if the certificate (a
  # Secret volume, updated in place by the kubelet) changed. Exits when
  # nginx does; SIGTERM stops nginx gracefully.
  run = ''
    nginx -g 'daemon off;' &
    n=$!
    trap 'nginx -s quit; wait $n; exit 0' TERM
    old=$(md5sum ${certFile})
    while kill -0 $n 2>/dev/null; do
      sleep 300 & wait $!
      new=$(md5sum ${certFile})
      if [ "$new" != "$old" ]; then nginx -s reload && old=$new; fi
    done
    exit 1
  '';
in
{
  validation.strict = true;

  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "privileged";
  };

  resources.core.v1.ConfigMap.${name} = {
    metadata = { inherit namespace; };
    data."nginx.conf" = nginxConf;
  };

  resources.apps.v1.DaemonSet.${name} = {
    metadata = { inherit namespace labels; };
    spec = {
      selector.matchLabels = labels;
      updateStrategy = {
        type = "RollingUpdate";
        rollingUpdate.maxUnavailable = 1;
      };
      template = {
        metadata = {
          inherit labels;
          annotations."cluster/config-hash" = builtins.hashString "sha256" nginxConf;
        };
        spec = {
          nodeSelector."kubernetes.io/hostname" = node;
          tolerations = k8sLib.nodeTolerations;
          automountServiceAccountToken = false;
          securityContext.seccompProfile.type = "RuntimeDefault";
          terminationGracePeriodSeconds = 30;
          containers = [
            {
              name = "nginx";
              image = "docker.io/nginxinc/nginx-unprivileged:1.31.7-alpine";
              command = [
                "/bin/sh"
                "-c"
                run
              ];
              # portmap DNAT: only traffic to the node's LAN IP.
              ports = [
                {
                  name = "https";
                  containerPort = port;
                  hostPort = 443;
                  hostIP = cluster.nodes.${node}.lanIP;
                  protocol = "TCP";
                }
              ];
              securityContext = {
                allowPrivilegeEscalation = false;
                readOnlyRootFilesystem = true;
                runAsNonRoot = true;
                runAsUser = 101;
                runAsGroup = 101;
                capabilities.drop = [ "ALL" ];
              };
              readinessProbe.tcpSocket.port = port;
              livenessProbe = {
                tcpSocket.port = port;
                periodSeconds = 20;
              };
              resources = {
                requests = {
                  cpu = "10m";
                  memory = "16Mi";
                };
                limits.memory = "128Mi";
              };
              volumeMounts = [
                {
                  name = "config";
                  mountPath = "/etc/nginx/nginx.conf";
                  subPath = "nginx.conf";
                  readOnly = true;
                }
                {
                  name = "tls";
                  mountPath = "/etc/nginx/tls";
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
              name = "tls";
              secret = {
                secretName = tlsSecret;
                defaultMode = 292; # 0444
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
