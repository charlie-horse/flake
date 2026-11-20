# step-ca + nginx TLS sidecar, one replica (replay protection of one-time
# tokens is in step-ca's memory), Service on the fixed ClusterIP
# cluster.stepCa.serviceIP.
#
# Neither process reloads its certs: each container records the revision
# of its mounted Secrets at start (the `..data` link of the volume) and its
# liveness probe fails once cert-manager has renewed one, so the kubelet
# restarts it. step-ca disables the provisioner for good when authentik's
# discovery fails at start ("failed to initialize", in its log); the probe
# fails on that line too, so step-ca retries by restarting.
{
  lib,
  cluster,
  ...
}:
let
  settings = import ./settings.nix;
  inherit (settings) namespace name;
  labels."app.kubernetes.io/name" = name;

  caJson = builtins.toJSON (
    import ./ca-json.nix {
      inherit lib settings;
      issuer = "https://${cluster.authentik.host}${settings.issuerPath}";
    }
  );
  nginxConf =
    lib.replaceStrings
      [ "@PROXY_PORT@" "@CA_PORT@" ]
      [ (toString settings.proxyPort) (toString settings.caPort) ]
      (builtins.readFile ./nginx.conf);

  containerSecurity = {
    allowPrivilegeEscalation = false;
    readOnlyRootFilesystem = true;
    runAsNonRoot = true;
    capabilities.drop = [ "ALL" ];
  };

  # Start `exec` after recording the Secret volumes' revisions; the probe
  # compares them.
  revFile = "/tmp/secret-revisions";
  revisions = dirs: lib.concatMapStringsSep "; " (d: "readlink ${d}/..data") dirs;
  startScript = dirs: exec: [
    "/bin/sh"
    "-c"
    "(${revisions dirs}) > ${revFile} && exec ${exec}"
  ];
  stepCaLog = "/tmp/step-ca.log";
  unchangedProbe = dirs: extra: {
    exec.command = [
      "/bin/sh"
      "-c"
      "[ \"$(${revisions dirs})\" = \"$(cat ${revFile})\" ]${extra}"
    ];
    periodSeconds = 60;
    failureThreshold = 1;
  };

  mount = volume: mountPath: {
    name = volume;
    inherit mountPath;
    readOnly = true;
  };
  tmp = {
    name = "tmp";
    mountPath = "/tmp";
  };
in
{
  resources.core.v1.ConfigMap.${name} = {
    metadata = { inherit namespace; };
    data = {
      "ca.json" = caJson;
      "nginx.conf" = nginxConf;
    };
  };

  resources.apps.v1.Deployment.${name} = {
    metadata = { inherit namespace labels; };
    spec = {
      replicas = 1;
      strategy.type = "Recreate";
      selector.matchLabels = labels;
      template = {
        metadata = {
          inherit labels;
          annotations."cluster/config-hash" = builtins.hashString "sha256" (caJson + nginxConf);
        };
        spec = {
          automountServiceAccountToken = false;
          securityContext = {
            seccompProfile.type = "RuntimeDefault";
            runAsNonRoot = true;
            # Group of the Secret files; only step-ca (gid 1000) mounts the SSH key.
            fsGroup = 1000;
          };
          containers = [
            {
              name = "step-ca";
              image = settings.images.stepCa;
              command = startScript [
                "/internal-ca"
                "/ssh-user-ca"
              ] "step-ca /config/ca.json 2>&1 | tee ${stepCaLog}";
              securityContext = containerSecurity // {
                runAsUser = 1000;
                runAsGroup = 1000;
              };
              readinessProbe.exec.command = [
                "step"
                "ca"
                "health"
                "--ca-url"
                "https://127.0.0.1:${toString settings.caPort}"
                "--root"
                "/internal-ca/ca.crt"
              ];
              livenessProbe = unchangedProbe [
                "/internal-ca"
                "/ssh-user-ca"
              ] " && ! grep -q 'failed to initialize' ${stepCaLog}";
              resources = {
                requests = {
                  cpu = "10m";
                  memory = "32Mi";
                };
                limits.memory = "128Mi";
              };
              volumeMounts = [
                (mount "config" "/config")
                (mount "internal-ca" "/internal-ca")
                (mount "ssh-user-ca" "/ssh-user-ca")
                tmp
              ];
            }
            {
              name = "nginx";
              image = settings.images.nginx;
              command = startScript [ "/internal-ca" "/tls" ] "nginx -c /config/nginx.conf -g 'daemon off;'";
              securityContext = containerSecurity // {
                runAsUser = 101;
                runAsGroup = 101;
              };
              ports = [
                {
                  name = "https";
                  containerPort = settings.proxyPort;
                }
              ];
              readinessProbe.tcpSocket.port = settings.proxyPort;
              livenessProbe = unchangedProbe [ "/internal-ca" "/tls" ] "";
              resources = {
                requests = {
                  cpu = "10m";
                  memory = "16Mi";
                };
                limits.memory = "64Mi";
              };
              volumeMounts = [
                (mount "config" "/config")
                (mount "internal-ca" "/internal-ca")
                (mount "tls" "/tls")
                tmp
              ];
            }
          ];
          volumes = [
            {
              name = "config";
              configMap.name = name;
            }
            {
              name = "internal-ca";
              secret = {
                secretName = settings.internalCASecret;
                defaultMode = 292; # 0444: step-ca (1000) and nginx (101) both read it
              };
            }
            {
              name = "ssh-user-ca";
              secret = {
                secretName = settings.userKeySecret;
                items = [
                  {
                    key = "key";
                    path = "key";
                  }
                ];
                defaultMode = 288; # 0440, group fsGroup
              };
            }
            {
              name = "tls";
              secret.secretName = settings.tlsSecret;
            }
            {
              name = "tmp";
              emptyDir.medium = "Memory";
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
      clusterIP = cluster.stepCa.serviceIP;
      ports = [
        {
          name = "https";
          inherit (settings) port;
          targetPort = "https";
        }
      ];
    };
  };
}
