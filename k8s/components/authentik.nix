# authentik (SSO / OIDC identity provider), namespace `authentik`.
#
#   server, worker  the authentik Helm chart (charts.authentik, image
#                   ghcr.io/goauthentik/server). amd64 only (nodeSelector):
#                   with c4130 tainted for vLLM that means r440. m2mini
#                   (arm64, 16 KiB pages) is avoided on purpose.
#   postgresql      a plain StatefulSet (official postgres image, not the
#                   chart's bundled subchart), data on m2mini's NVMe
#                   (hostPath PV, /var/lib/authentik/postgres). r440's root
#                   is the 5400 rpm HDD that already slows its etcd WAL.
#   backup          CronJob, daily `pg_dump -Fc` to r440
#                   (/var/lib/authentik/backup, 14 kept).
#   blueprint       ConfigMap `authentik-blueprints`: the OIDC provider and
#                   application `kubernetes` plus the group `cluster-admins`
#                   for kube-apiserver logins (see k8s/README.md, "authentik").
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
# Public at https://auth.neuros.is (cluster.authentik.host): the
# Cloudflare tunnel on c4130 (hosts/c4130/cloudflared.nix) forwards to
# Service authentik-server at the fixed ClusterIP cluster.authentik.serviceIP
# (port 80), through c4130's kube-proxy. ClusterIP is immutable, so that
# Service carries Flux's force annotation (recreated, not patched, if the
# IP ever changes). From inside the tailnet/LAN without the tunnel:
#   kubectl -n authentik port-forward svc/authentik-server 9000:80
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

  # hostPath PV pinned to one node and pre-bound to one claim.
  localVolume =
    {
      name,
      node,
      path,
      size,
    }:
    {
      resources.core.v1.PersistentVolume.${name}.spec = {
        capacity.storage = size;
        accessModes = [ "ReadWriteOnce" ];
        persistentVolumeReclaimPolicy = "Retain";
        storageClassName = "local";
        volumeMode = "Filesystem";
        hostPath = {
          inherit path;
          type = "DirectoryOrCreate";
        };
        claimRef = {
          inherit namespace name;
        };
        nodeAffinity.required.nodeSelectorTerms = [
          {
            matchExpressions = [
              {
                key = "kubernetes.io/hostname";
                operator = "In";
                values = [ node ];
              }
            ];
          }
        ];
      };
      resources.core.v1.PersistentVolumeClaim.${name} = {
        metadata = { inherit namespace; };
        spec = {
          accessModes = [ "ReadWriteOnce" ];
          storageClassName = "local";
          volumeName = name;
          resources.requests.storage = size;
        };
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
  '';

  # Scheduling, sizing and hardening shared by server and worker. The image
  # runs as `authentik` (uid 1000), so both meet `restricted`.
  common = {
    nodeSelector."kubernetes.io/arch" = "amd64";
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
      patch =
        manifest:
        if manifest.kind == "Service" && manifest.metadata.name == "authentik-server" then
          lib.recursiveUpdate manifest {
            metadata.annotations."kustomize.toolkit.fluxcd.io/force" = "enabled";
            spec.clusterIP = cluster.authentik.serviceIP;
          }
        else
          manifest;
      values = {
        global.env = lib.mapAttrsToList (name: value: { inherit name value; }) {
          AUTHENTIK_POSTGRESQL__HOST = db.name;
          AUTHENTIK_POSTGRESQL__NAME = db.database;
          AUTHENTIK_POSTGRESQL__USER = db.user;
          AUTHENTIK_LOG_LEVEL = "info";
          AUTHENTIK_ERROR_REPORTING__ENABLED = "false";
        };
        # Only secrets live there; everything else is global.env above.
        authentik.existingSecret.secretName = secretName;
        blueprints.configMaps = [ blueprintsConfigMap ];
        postgresql.enabled = false;
        server = common;
        worker = common;
      };
    })
    (localVolume {
      name = db.name;
      node = "m2mini";
      path = "/var/lib/authentik/postgres";
      size = "10Gi";
    })
    (localVolume {
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
