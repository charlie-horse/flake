# Headlamp (Kubernetes web UI), namespace `headlamp`: the Headlamp Helm
# chart, one replica, amd64 only (nodeSelector): with c4130 tainted, r440.
#
# Login is OIDC against authentik's confidential provider `headlamp`
# (per-provider issuer, a second JWT authenticator on the apiserver:
# cluster.oidc.extraIssuers). Headlamp hands each user's own ID token to the
# apiserver; the pod's ServiceAccount has NO RBAC (the chart's cluster-admin
# binding is disabled, unsafeUseServiceAccountToken off).
#
# Secret headlamp-oidc (sops, key OIDC_CLIENT_SECRET, copied from authentik),
# read at start. The namespace enforces `restricted`. Public at
# https://k8s.neuros.is through apps/cloudflared to the fixed ClusterIP
# cluster.headlamp.serviceIP. Docs: docs/k8s/apps.md#headlamp
{
  pkgs,
  catenix,
  charts,
  cluster,
  kubeVersion,
  k8sLib,
  ...
}:
let
  namespace = "headlamp";
  secretName = "headlamp-oidc";
in
{
  imports = [
    (catenix.importChart {
      inherit pkgs kubeVersion;
      chart = charts.headlamp;
      release = {
        name = "headlamp";
        inherit namespace;
      };
      patch = k8sLib.fixedServiceIP {
        service = "headlamp";
        ip = cluster.headlamp.serviceIP;
      };
      values = {
        fullnameOverride = "headlamp";
        replicaCount = 1;

        initContainers = [
          {
            command = [
              "/bin/sh"
              "-c"
              "mkdir -p /build/plugins && cp -r /plugins/* /build/plugins/"
            ];
            image = "ghcr.io/headlamp-k8s/headlamp-plugin-flux:v0.7.0";
            imagePullPolicy = "Always";
            name = "headlamp-plugin-flux";
            securityContext = {
              runAsNonRoot = true;
              privileged = false;
              runAsUser = 100;
              runAsGroup = 101;
              allowPrivilegeEscalation = false;
              capabilities.drop = [ "ALL" ];
              seccompProfile.type = "RuntimeDefault";
            };

            volumeMounts = [
              {
                mountPath = "/build/plugins";
                name = "headlamp-plugins";
              }
            ];
          }
        ];

        volumes = [
          {
            name = "headlamp-plugins";
            emptyDir = { };
          }
        ];

        volumeMounts = [
          {
            mountPath = "/build/plugins";
            name = "headlamp-plugins";
          }
        ];

        config = {
          pluginsDir = "/build/plugins";
          inCluster = true;
          unsafeUseServiceAccountToken = false;
          oidc = {
            # Neither the chart's own Secret (it would hold the client
            # secret, in git) nor envFrom an external one: the non-secret
            # settings are plain env values, the client secret is one
            # secretKeyRef (env below).
            secret.create = false;
            externalSecret.enabled = false;
            clientID = "headlamp";
            issuerURL = "https://auth.neuros.is/application/o/headlamp/";
            scopes = "openid profile email groups";
            callbackURL = "https://${cluster.headlamp.host}/oidc-callback";
          };
        };
        # Picked up by the chart as OIDC_CLIENT_SECRET, which also makes it
        # pass `-oidc-client-secret=$(OIDC_CLIENT_SECRET)`.
        env = [
          {
            name = "OIDC_CLIENT_SECRET";
            valueFrom.secretKeyRef = {
              name = secretName;
              key = "OIDC_CLIENT_SECRET";
            };
          }
        ];

        # Own ServiceAccount, bound to nothing.
        serviceAccount.create = true;
        clusterRoleBinding.create = false;

        service = {
          type = "ClusterIP";
          port = 80;
        };
        ingress.enabled = false;

        nodeSelector."kubernetes.io/arch" = "amd64";

        podSecurityContext = {
          runAsNonRoot = true;
          seccompProfile.type = "RuntimeDefault";
        };
        securityContext = {
          runAsNonRoot = true;
          runAsUser = 100;
          runAsGroup = 101;
          privileged = false;
          allowPrivilegeEscalation = false;
          capabilities.drop = [ "ALL" ];
          seccompProfile.type = "RuntimeDefault";
        };
        resources = {
          requests = {
            cpu = "50m";
            memory = "128Mi";
          };
          limits.memory = "512Mi";
        };
      };
    })
  ];

  validation.strict = true;

  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "restricted";
    "pod-security.kubernetes.io/warn" = "restricted";
  };
}
