# cloudflared: the cluster's ONE Cloudflare tunnel (cluster.tunnel, named
# `cluster`), namespace `cloudflared`. Every public hostname goes through it:
#
#   https://<host> -> Cloudflare edge -> cloudflared (any replica)
#     -> nginx sidecar on 127.0.0.1:9190 (same pod)
#     -> http://<service ClusterIP>:80 (cluster.<service>.serviceIP)
#
#   auth.neuros.is  authentik   (components/authentik.nix)
#   k8s.neuros.is   Headlamp    (components/headlamp.nix)
#   chat.neuros.is  Open WebUI  (components/open-webui.nix)
#
# One replica per node (required pod anti-affinity, the GPU taint
# tolerated), so the tunnel has a connector on every node and keeps serving
# while any node is down. Cloudflare balances between the connectors.
#
# hostNetwork, on purpose: the nginx sidecar's connections to the
# ClusterIPs then leave from the node's own addresses (kube-proxy picks
# cni0 10.244.N.1 or flannel.1 10.244.N.0 as source), and authentik trusts
# X-Forwarded-* only from those (AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS). An
# ordinary pod (10.244.N.2 and up) can therefore not forge a client IP.
# hostNetwork is why the namespace is `privileged` for Pod Security; the
# containers themselves run unprivileged, read-only and with no
# capabilities. Both listen on loopback only (nginx 9190, cloudflared's
# metrics 20250), so nothing is exposed on the nodes.
#
# Why nginx: Cloudflare APPENDS the visitor's IP to a client-sent
# X-Forwarded-For, and authentik (and Open WebUI) read the leftmost entry.
# Cloudflare's edge always sets Cf-Connecting-Ip itself, so nginx REPLACES
# X-Forwarded-For / X-Real-IP with it. Websockets pass through.
#
# The tunnel credential is NOT in git: Secret cloudflared/tunnel-credentials,
# key credentials.json (the JSON `cloudflared tunnel create` writes), made
# once by hand (k8s/README.md, "Cloudflare tunnel"). DNS: each hostname is a
# proxied CNAME to <tunnel id>.cfargotunnel.com:
#   cloudflared tunnel route dns --overwrite-dns <tunnel id> <hostname>
{ lib, cluster, ... }:
let
  namespace = "cloudflared";
  name = "cloudflared";
  labels."app.kubernetes.io/name" = "cloudflared";

  proxyPort = 9190;
  metricsPort = 20250;

  # Public hostname -> upstream (fixed ClusterIPs).
  routes = lib.listToAttrs (
    map (s: lib.nameValuePair cluster.${s}.host "${cluster.${s}.serviceIP}:80") [
      "authentik"
      "headlamp"
      "openWebui"
    ]
  );

  # Locally managed tunnel: these are its ingress rules. JSON is YAML.
  cloudflaredConfig = builtins.toJSON {
    tunnel = cluster.tunnel.id;
    credentials-file = "/etc/cloudflared/credentials/credentials.json";
    metrics = "127.0.0.1:${toString metricsPort}";
    no-autoupdate = true;
    ingress =
      map (host: {
        hostname = host;
        service = "http://127.0.0.1:${toString proxyPort}";
      }) (lib.attrNames routes)
      ++ [ { service = "http_status:404"; } ];
  };

  nginxConfig = ''
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

      # The visitor's IP as Cloudflare's edge saw it (a client cannot set
      # it); loopback if absent, i.e. not through Cloudflare.
      map $http_cf_connecting_ip $client_ip {
        ""      $remote_addr;
        default $http_cf_connecting_ip;
      }
      map $http_x_forwarded_proto $forwarded_proto {
        ""      https;
        default $http_x_forwarded_proto;
      }
      map $http_upgrade $connection_upgrade {
        default upgrade;
        ""      close;
      }
      map $host $upstream {
        hostnames;
        default "";
    ${lib.concatStrings (lib.mapAttrsToList (h: u: "    ${h} ${u};\n") routes)}  }

      server {
        listen 127.0.0.1:${toString proxyPort};
        location / {
          if ($upstream = "") { return 404; }
          proxy_pass http://$upstream;
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection $connection_upgrade;
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-For $client_ip;
          proxy_set_header X-Real-IP $client_ip;
          proxy_set_header X-Forwarded-Proto $forwarded_proto;
          proxy_set_header X-Forwarded-Host $host;
          # Long-lived: chat completions stream, websockets.
          proxy_read_timeout 3600s;
          proxy_send_timeout 3600s;
          proxy_buffering off;
          proxy_request_buffering off;
          client_max_body_size 256m;
        }
      }
    }
  '';

  # Tolerate every taint a node carries (c4130: nvidia.com/gpu=vllm), so
  # there is a connector on every node.
  tolerations = lib.unique (
    lib.concatMap (
      n:
      lib.mapAttrsToList (_: t: {
        key = t.key;
        operator = "Equal";
        value = t.value;
        effect = t.effect;
      }) (n.taints or { })
    ) (lib.attrValues cluster.nodes)
  );

  containerSecurity = {
    allowPrivilegeEscalation = false;
    readOnlyRootFilesystem = true;
    runAsNonRoot = true;
    capabilities.drop = [ "ALL" ];
  };
in
{
  validation.strict = true;

  # privileged: hostNetwork (see above); the containers are unprivileged.
  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "privileged";
    "pod-security.kubernetes.io/warn" = "baseline";
  };

  resources.core.v1.ConfigMap.${name} = {
    metadata = { inherit namespace; };
    data = {
      "config.yaml" = cloudflaredConfig;
      "nginx.conf" = nginxConfig;
    };
  };

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
          annotations."solaris/config-hash" = builtins.hashString "sha256" (cloudflaredConfig + nginxConfig);
        };
        spec = {
          hostNetwork = true;
          dnsPolicy = "ClusterFirstWithHostNet";
          inherit tolerations;
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
                port = metricsPort;
                path = "/ready";
              };
              livenessProbe = {
                httpGet = {
                  host = "127.0.0.1";
                  port = metricsPort;
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
                port = proxyPort;
              };
              livenessProbe = {
                tcpSocket = {
                  host = "127.0.0.1";
                  port = proxyPort;
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
