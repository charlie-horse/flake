# Names shared by the tranquil-pds files (plain data).
rec {
  namespace = "atproto";

  # sops: k8s/secrets/atproto/tranquil-pds-secrets.sops.yaml.
  secretName = "tranquil-pds-secrets";

  db = {
    name = "tranquil-pds-postgresql";
    database = "pds";
    user = "tranquil_pds";
    image = "docker.io/library/postgres:18.7-trixie";
    labels = {
      "app.kubernetes.io/name" = "postgresql";
      "app.kubernetes.io/instance" = "tranquil-pds";
    };
    password.secretKeyRef = {
      name = secretName;
      key = "POSTGRES_PASSWORD";
    };
  };
}
