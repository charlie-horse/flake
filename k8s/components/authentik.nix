# authentik (SSO / OIDC identity provider), namespace `authentik`.
#
#   server, worker  the authentik Helm chart (charts.authentik, image
#                   ghcr.io/goauthentik/server). One of each per node
#                   (replicas = node count, the chart's "hard" pod
#                   anti-affinity, c4130's GPU taint tolerated), so login
#                   survives any one node being down. PostgreSQL is still a
#                   single instance (below).
#   postgresql      a plain StatefulSet (official postgres image, not the
#                   chart's bundled subchart), data on m2mini's NVMe
#                   (hostPath PV, /var/lib/authentik/postgres). r440's root
#                   is the 5400 rpm HDD that already slows its etcd WAL.
#   backup          CronJob, daily `pg_dump -Fc` to r440
#                   (/var/lib/authentik/backup, 14 kept).
#   blueprint       ConfigMap `authentik-blueprints`: the OIDC providers and
#                   applications `kubernetes` (kubectl, public) and
#                   `headlamp` (Headlamp, confidential) plus the group
#                   `cluster-admins` for kube-apiserver logins (see
#                   k8s/README.md, "authentik").
#
# Secrets are NOT in git. The pods read the Secret `authentik-secrets`
# (created once by hand, never by Flux; Flux does not prune what it did not
# create). Keys:
#   AUTHENTIK_SECRET_KEY            random, >= 50 chars; never change it
#   AUTHENTIK_POSTGRESQL__PASSWORD  also POSTGRES_PASSWORD of the database
#   AUTHENTIK_BOOTSTRAP_PASSWORD    password of `akadmin` on first start
# Creating it is in k8s/README.md. Until it exists the pods stay in
# CreateContainerConfigError, nothing else breaks.
#
# Pod security: the namespace enforces `baseline` (postgres starts as
# root) and warns on `restricted`; server and worker meet `restricted`.
#
# Public at https://auth.neuros.is (cluster.authentik.host): the cluster's
# Cloudflare tunnel (components/cloudflared.nix, one replica per node)
# forwards to Service authentik-server at the fixed ClusterIP
# cluster.authentik.serviceIP (port 80). ClusterIP is immutable, so that
# Service carries Flux's force annotation (recreated, not patched, if the
# IP ever changes). From inside the tailnet/LAN without the tunnel:
#   kubectl -n authentik port-forward svc/authentik-server 9000:80
{
  lib,
  pkgs,
  catenix,
  charts,
  cluster,
  k8sLib,
  kubeVersion,
  ...
}:
let
  namespace = "authentik";
  secretName = "authentik-secrets";
  blueprintsConfigMap = "authentik-blueprints";

  db = {
    name = "authentik-postgresql";
    database = "authentik";
    user = "authentik";
    # Same major as the chart's own (disabled) postgresql default.
    image = "docker.io/library/postgres:17.11-trixie";
    labels = {
      "app.kubernetes.io/name" = "postgresql";
      "app.kubernetes.io/instance" = "authentik";
      "app.kubernetes.io/part-of" = "authentik";
    };
  };

  dbPassword = {
    secretKeyRef = {
      name = secretName;
      key = "AUTHENTIK_POSTGRESQL__PASSWORD";
    };
  };

  # The official image's entrypoint starts as root, chowns PGDATA and drops
  # to the postgres user (gosu), so this pod is `baseline`, not
  # `restricted`. PGDATA is a subdirectory: the mount point itself is
  # created root-owned by the kubelet.
  postgres = {
    resources.apps.v1.StatefulSet.${db.name} = {
      metadata = {
        inherit namespace;
        labels = db.labels;
      };
      spec = {
        serviceName = db.name;
        replicas = 1;
        selector.matchLabels = db.labels;
        template = {
          metadata.labels = db.labels;
          spec = {
            securityContext.seccompProfile.type = "RuntimeDefault";
            terminationGracePeriodSeconds = 60;
            containers = [
              {
                name = "postgresql";
                inherit (db) image;
                env = [
                  {
                    name = "POSTGRES_DB";
                    value = db.database;
                  }
                  {
                    name = "POSTGRES_USER";
                    value = db.user;
                  }
                  {
                    name = "POSTGRES_PASSWORD";
                    valueFrom = dbPassword;
                  }
                  {
                    name = "PGDATA";
                    value = "/var/lib/postgresql/data/pgdata";
                  }
                ];
                ports = [
                  {
                    name = "postgresql";
                    containerPort = 5432;
                  }
                ];
                readinessProbe = {
                  exec.command = [
                    "pg_isready"
                    "-U"
                    db.user
                    "-d"
                    db.database
                  ];
                  periodSeconds = 10;
                };
                livenessProbe = {
                  exec.command = [
                    "pg_isready"
                    "-U"
                    db.user
                    "-d"
                    db.database
                  ];
                  initialDelaySeconds = 30;
                  periodSeconds = 20;
                  failureThreshold = 6;
                };
                securityContext.allowPrivilegeEscalation = false;
                resources = {
                  requests = {
                    cpu = "50m";
                    memory = "256Mi";
                  };
                  limits.memory = "1Gi";
                };
                volumeMounts = [
                  {
                    name = "data";
                    mountPath = "/var/lib/postgresql/data";
                  }
                  {
                    name = "shm";
                    mountPath = "/dev/shm";
                  }
                ];
              }
            ];
            volumes = [
              {
                name = "data";
                persistentVolumeClaim.claimName = db.name;
              }
              {
                name = "shm";
                emptyDir = {
                  medium = "Memory";
                  sizeLimit = "256Mi";
                };
              }
            ];
          };
        };
      };
    };

    resources.core.v1.Service.${db.name} = {
      metadata = {
        inherit namespace;
        labels = db.labels;
      };
      spec = {
        selector = db.labels;
        ports = [
          {
            name = "postgresql";
            port = 5432;
            targetPort = "postgresql";
          }
        ];
      };
    };
  };

  backupName = "authentik-backup";
  backup = {
    # Runs on r440 (the backup PV's node affinity). Keeps the newest 14.
    resources.batch.v1.CronJob.${backupName} = {
      metadata = { inherit namespace; };
      spec = {
        schedule = "17 3 * * *";
        timeZone = "America/New_York";
        concurrencyPolicy = "Forbid";
        successfulJobsHistoryLimit = 3;
        failedJobsHistoryLimit = 3;
        jobTemplate.spec = {
          backoffLimit = 2;
          template.spec = {
            restartPolicy = "OnFailure";
            securityContext.seccompProfile.type = "RuntimeDefault";
            containers = [
              {
                name = "pg-dump";
                inherit (db) image;
                env = [
                  {
                    name = "PGPASSWORD";
                    valueFrom = dbPassword;
                  }
                ];
                command = [
                  "/bin/sh"
                  "-ec"
                  ''
                    f=/backup/authentik-$(date +%Y%m%dT%H%M%S).dump
                    pg_dump -h ${db.name} -U ${db.user} -d ${db.database} -Fc -f "$f.part"
                    mv "$f.part" "$f"
                    ls -1t /backup/authentik-*.dump | tail -n +15 | xargs -r rm --
                    ls -l /backup
                  ''
                ];
                securityContext.allowPrivilegeEscalation = false;
                resources = {
                  requests = {
                    cpu = "10m";
                    memory = "64Mi";
                  };
                  limits.memory = "512Mi";
                };
                volumeMounts = [
                  {
                    name = "backup";
                    mountPath = "/backup";
                  }
                ];
              }
            ];
            volumes = [
              {
                name = "backup";
                persistentVolumeClaim.claimName = backupName;
              }
            ];
          };
        };
      };
    };
  };

  # Blueprint (YAML with authentik's custom tags, applied by the worker,
  # re-applied on change and hourly). kubectl/kubelogin use the public
  # client `kubernetes` with PKCE; kubelogin's default callbacks are
  # localhost:8000 and :18000.
  blueprint = ''
    version: 1
    metadata:
      name: solaris - kubernetes OIDC
      labels:
        blueprints.goauthentik.io/description: kube-apiserver OIDC client (k8s/components/authentik.nix)
    entries:
      - model: authentik_core.group
        id: cluster-admins
        identifiers:
          name: cluster-admins
        attrs:
          name: cluster-admins

      - model: authentik_providers_oauth2.oauth2provider
        id: provider
        identifiers:
          name: kubernetes
        attrs:
          name: kubernetes
          client_type: public
          client_id: kubernetes
          # authentik >= 2026.x allows only the listed grants (empty = none):
          # the browser login (code + PKCE) and kubelogin's silent renewals.
          grant_types:
            - authorization_code
            - refresh_token
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          signing_key: !Find [authentik_crypto.certificatekeypair, [name, authentik Self-signed Certificate]]
          issuer_mode: per_provider
          sub_mode: hashed_user_id
          include_claims_in_id_token: true
          access_token_validity: minutes=15
          refresh_token_validity: days=7
          redirect_uris:
            - matching_mode: strict
              url: http://localhost:8000
            - matching_mode: strict
              url: http://localhost:18000
          property_mappings:
            - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-openid]]
            - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-email]]
            - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-profile]]
            - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-offline_access]]

      - model: authentik_core.application
        id: application
        identifiers:
          slug: kubernetes
        attrs:
          name: Kubernetes (solaris)
          provider: !KeyOf provider
          policy_engine_mode: any

      # Only members of cluster-admins may log in to the cluster.
      - model: authentik_policies.policybinding
        identifiers:
          target: !KeyOf application
          group: !KeyOf cluster-admins
        attrs:
          order: 0

      # Headlamp (k8s/components/headlamp.nix): confidential client. Headlamp
      # forwards the ID token to the apiserver, which trusts this provider's
      # issuer (.../application/o/headlamp/) with audience `headlamp`
      # (cluster/definition.nix oidc.extraIssuers). authentik generates the
      # client secret; it goes into the hand-made Secret headlamp/headlamp-oidc
      # (k8s/README.md), never into git.
      - model: authentik_providers_oauth2.oauth2provider
        id: headlamp-provider
        identifiers:
          name: headlamp
        attrs:
          name: headlamp
          client_type: confidential
          client_id: headlamp
          # Same as `kubernetes`: only listed grants are allowed (empty = none).
          grant_types:
            - authorization_code
            - refresh_token
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          signing_key: !Find [authentik_crypto.certificatekeypair, [name, authentik Self-signed Certificate]]
          issuer_mode: per_provider
          sub_mode: hashed_user_id
          include_claims_in_id_token: true
          access_token_validity: minutes=15
          refresh_token_validity: days=1
          redirect_uris:
            - matching_mode: strict
              url: https://${cluster.headlamp.host}/oidc-callback
          property_mappings:
            - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-openid]]
            - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-email]]
            - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-profile]]
            - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-offline_access]]

      - model: authentik_core.application
        id: headlamp-application
        identifiers:
          slug: headlamp
        attrs:
          name: Headlamp (solaris)
          provider: !KeyOf headlamp-provider
          meta_launch_url: https://${cluster.headlamp.host}/
          policy_engine_mode: any

      - model: authentik_policies.policybinding
        identifiers:
          target: !KeyOf headlamp-application
          group: !KeyOf cluster-admins
        attrs:
          order: 0

      # Open WebUI (k8s/components/open-webui.nix): confidential client; its
      # secret is generated by authentik on creation (never in git) and
      # copied into the Secret open-webui/open-webui-secrets.
      - model: authentik_core.group
        id: local-ai
        identifiers:
          name: local-ai
        attrs:
          name: local-ai

      - model: authentik_providers_oauth2.oauth2provider
        id: open-webui-provider
        identifiers:
          name: open-webui
        attrs:
          name: open-webui
          client_type: confidential
          client_id: open-webui
          grant_types:
            - authorization_code
            - refresh_token
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          signing_key: !Find [authentik_crypto.certificatekeypair, [name, authentik Self-signed Certificate]]
          issuer_mode: per_provider
          sub_mode: hashed_user_id
          include_claims_in_id_token: true
          access_token_validity: minutes=15
          refresh_token_validity: days=30
          redirect_uris:
            - matching_mode: strict
              url: https://${cluster.openWebui.host}/oauth/oidc/callback
          property_mappings:
            - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-openid]]
            - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-email]]
            - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-profile]]

      - model: authentik_core.application
        id: open-webui-application
        identifiers:
          slug: open-webui
        attrs:
          name: Open WebUI
          provider: !KeyOf open-webui-provider
          meta_launch_url: https://${cluster.openWebui.host}/
          policy_engine_mode: any

      # Only members of local-ai may log in to Open WebUI.
      - model: authentik_policies.policybinding
        identifiers:
          target: !KeyOf open-webui-application
          group: !KeyOf local-ai
        attrs:
          order: 0
  '';

  # Scheduling, sizing and hardening shared by server and worker. The image
  # runs as `authentik` (uid 1000), so both meet `restricted`.
  common = {
    replicas = lib.length (lib.attrNames cluster.nodes);
    # One per node (hard anti-affinity) leaves no node for a surge pod, and
    # the old pod would never go: replace one at a time instead.
    deploymentStrategy = {
      type = "RollingUpdate";
      rollingUpdate = {
        maxSurge = 0;
        maxUnavailable = 1;
      };
    };
    # Every node's taints (c4130: nvidia.com/gpu=vllm), so one lands on each.
    tolerations = k8sLib.nodeTolerations;
    securityContext = {
      runAsNonRoot = true;
      seccompProfile.type = "RuntimeDefault";
    };
    containerSecurityContext = {
      allowPrivilegeEscalation = false;
      capabilities.drop = [ "ALL" ];
    };
    resources = {
      requests = {
        cpu = "100m";
        memory = "512Mi";
      };
      limits.memory = "1536Mi";
    };
  };
in
{
  imports = [
    (catenix.importChart {
      inherit pkgs kubeVersion;
      chart = charts.authentik;
      release = {
        name = "authentik";
        inherit namespace;
      };
      patch = k8sLib.fixedServiceIP {
        service = "authentik-server";
        ip = cluster.authentik.serviceIP;
      };
      values = {
        global.env = lib.mapAttrsToList (name: value: { inherit name value; }) {
          AUTHENTIK_POSTGRESQL__HOST = db.name;
          AUTHENTIK_POSTGRESQL__NAME = db.database;
          AUTHENTIK_POSTGRESQL__USER = db.user;
          AUTHENTIK_LOG_LEVEL = "info";
          AUTHENTIK_ERROR_REPORTING__ENABLED = "false";
          # Honour X-Forwarded-For/-Proto only from the tunnel's proxies: the
          # in-cluster cloudflared + nginx (components/cloudflared.nix) run
          # with hostNetwork on every node, so they reach the ClusterIP from
          # that node's cni0 (10.244.N.1) or flannel.1 (10.244.N.0) address
          # (node podCIDRs: r440 .0, c4130 .1, m2mini .2), plus the nodes' LAN
          # IPs and loopback for the healthchecks. Ordinary pods get .2 and up,
          # so they cannot forge client IPs (authentik's default trusts all of
          # 10/8). -Proto must stay trusted from the proxies, or the issuer
          # would be http://.
          AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS = lib.concatStringsSep "," (
            [
              "10.244.0.0/31"
              "10.244.1.0/31"
              "10.244.2.0/31"
              "127.0.0.1/32"
              "::1/128"
            ]
            ++ map (n: "${n.lanIP}/32") (lib.attrValues cluster.nodes)
          );
        };
        # Only secrets live there; everything else is global.env above.
        authentik.existingSecret.secretName = secretName;
        blueprints.configMaps = [ blueprintsConfigMap ];
        postgresql.enabled = false;
        # Required anti-affinity on kubernetes.io/hostname: one per node.
        global.affinity.podAntiAffinity = "hard";
        server = common;
        worker = common;
      };
    })
    (k8sLib.localVolume {
      inherit namespace;
      name = db.name;
      node = "m2mini";
      path = "/var/lib/authentik/postgres";
      size = "10Gi";
    })
    (k8sLib.localVolume {
      inherit namespace;
      name = backupName;
      node = "r440";
      path = "/var/lib/authentik/backup";
      size = "20Gi";
    })
    postgres
    backup
  ];

  validation.strict = true;

  # baseline: the postgres entrypoint starts as root (see above).
  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "baseline";
    "pod-security.kubernetes.io/warn" = "restricted";
  };

  resources.core.v1.ConfigMap.${blueprintsConfigMap} = {
    metadata = { inherit namespace; };
    data."kubernetes-oidc.yaml" = blueprint;
  };
}
