# Names shared by the authentik files (plain data).
rec {
  namespace = "authentik";

  # sops-encrypted in k8s/secrets/authentik/authentik-secrets.sops.yaml,
  # applied by the Flux Kustomization `secrets` (k8s/README.md, "Secrets",
  # "authentik"): keys AUTHENTIK_SECRET_KEY, AUTHENTIK_POSTGRESQL__PASSWORD,
  # AUTHENTIK_BOOTSTRAP_PASSWORD.
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
    # POSTGRES_PASSWORD / PGPASSWORD for the database and its backup.
    password.secretKeyRef = {
      name = secretName;
      key = "AUTHENTIK_POSTGRESQL__PASSWORD";
    };
  };

  backupName = "authentik-backup";
}
