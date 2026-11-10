# Headlamp (Kubernetes web UI), namespace `headlamp`: the Headlamp Helm
# chart (charts.headlamp, image ghcr.io/headlamp-k8s/headlamp), one replica,
# amd64 only (nodeSelector): with c4130 tainted for vLLM that means r440.
# m2mini (arm64, 16 KiB pages) is avoided on purpose, as for authentik.
#
# Login is OIDC against authentik's confidential provider `headlamp`
# (issuer https://auth.neuros.is/application/o/headlamp/, per-provider),
# scopes `openid profile email groups`, callback
# https://<cluster.headlamp.host>/oidc-callback. Headlamp hands each user's
# own ID token to the apiserver, which accepts that issuer with audience
# `headlamp` (cluster.oidc.extraIssuers, modules/cluster/control-plane.nix)
# and maps it to oidc:<user> / oidc:<group>; RBAC binds oidc:cluster-admins
# (k8s/components/rbac.nix). The pod's own ServiceAccount has NO RBAC: the
# chart's default cluster-admin ClusterRoleBinding is disabled, and
# unsafeUseServiceAccountToken stays off. (The token is still mounted:
# in-cluster mode reads the apiserver address and CA from it.)
#
# The client secret is NOT in git. The pod reads it from the Secret
# `headlamp-oidc` (created once by hand, never by Flux), key
#   OIDC_CLIENT_SECRET   the `headlamp` provider's client secret, copied
#                        from authentik (Applications -> Providers ->
#                        headlamp); generate nothing here
# Client id, issuer, scopes and callback are plain env values below. Create
# it with the value on stdin, never on a command line:
#   (the namespace comes from Flux; this file must be applied first)
#   kubectl -n headlamp create secret generic headlamp-oidc --from-env-file=/dev/stdin
#   (then type or paste `OIDC_CLIENT_SECRET=<secret>`, Enter, Ctrl-D)
# Until it exists the pod stays in CreateContainerConfigError, nothing else
# breaks.
#
# Pod security: the namespace enforces `restricted` (the image runs as uid
# 100; non-root, seccomp RuntimeDefault, all capabilities dropped, no
# privilege escalation).
#
# No Ingress. Public at https://k8s.neuros.is (cluster.headlamp.host): the
# cluster's Cloudflare tunnel (components/cloudflared.nix, one replica per
# node, nginx sidecar keeps the Host header) forwards to Service headlamp at
# the fixed ClusterIP cluster.headlamp.serviceIP (port 80). ClusterIP is immutable, so that
# Service carries Flux's force annotation (recreated, not patched, if the IP
# ever changes). From inside the tailnet/LAN without the tunnel:
#   kubectl -n headlamp port-forward svc/headlamp 4466:80
{
  lib,
  pkgs,
  catenix,
  charts,
  cluster,
  kubeVersion,
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
      patch =
        manifest:
        if manifest.kind == "Service" && manifest.metadata.name == "headlamp" then
          lib.recursiveUpdate manifest {
            metadata.annotations."kustomize.toolkit.fluxcd.io/force" = "enabled";
            spec.clusterIP = cluster.headlamp.serviceIP;
          }
        else
          manifest;
      values = {
        fullnameOverride = "headlamp";
        replicaCount = 1;

        initContainers = [{
          command = [
            "/bin/sh -c mkdir -p /build/plugins &&"
            "cp -r /plugins/* /build/plugins &&"
            "chown -R 100:101 /build"
          ];
          image = "ghcr.io/headlamp-k8s/headlamp-plugin-flux:latest";
          imagePullPolicy = "Always";
          name = "headlamp-plugin-flux";
          securityContext = {
            runAsNonRoot = false;
            privileged = false;
            runAsUser = 0;
            runAsGroup = 0;
          };
          volumeMounts = [{
            mountPath = "/build/plugins";
            name = "headlamp-plugins";
          }];
        }];

        persistentVolumeClaim = {
          accessModes = [ "ReadWriteOnce" ];
          enabled = true;
          size = "1Gi";
        };

        volumes = [{
          name = "headlamp-plugins";
          persistentVolumeClaim.claimName = "headlamp";
        }];

        volumeMounts = [{
          mountPath = "/build/plugins";
          name = "headlamp-plugins";
        }];

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
