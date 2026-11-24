# Names shared by the atcr files (plain data).
rec {
  namespace = "atproto";

  # Images built by pkgs/atproto-images/atcr.nix and
  # pushed by .github/workflows/atproto-images.yml. A null digest keeps the
  # Deployment at 0 replicas.
  images = {
    appview = {
      repo = "ghcr.io/charlie-horse/flake/atcr-appview";
      digest = "sha256:41ddff611ee664b489028478f861f743637fc47bea342873f72c72a4393f4387";
    };
    hold = {
      repo = "ghcr.io/charlie-horse/flake/atcr-hold";
      digest = "sha256:2fc47df660d30318b4fa5008f7e036db2058aa85e1a4f037c9cac8dab86f40c7";
    };
  };
  imageRef = { repo, digest }: if digest == null then "${repo}:main" else "${repo}@${digest}";
  replicas = { digest, ... }: if digest == null then 0 else 1;

  # User of the atcr images.
  uid = 65532;

  # sops: k8s/secrets/atproto/atcr-secrets.sops.yaml (GARAGE_RPC_SECRET,
  # S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY).
  secretName = "atcr-secrets";

  garage = {
    name = "atcr-garage";
    image = "docker.io/dxflrs/garage:v2.5.0";
    s3Port = 3900;
    region = "garage";
  };
  bucket = "atcr-blobs";

  secretEnv = map (
    { env, key }:
    {
      name = env;
      valueFrom.secretKeyRef = {
        name = secretName;
        inherit key;
      };
    }
  );

  # Container defaults (PSA baseline; Garage runs as root).
  containerSecurity = {
    allowPrivilegeEscalation = false;
    capabilities.drop = [ "ALL" ];
  };

  # Pod settings of the atcr images: CI builds x86_64 only; runs as `uid`.
  podSpec = {
    nodeSelector."kubernetes.io/arch" = "amd64";
    securityContext = {
      seccompProfile.type = "RuntimeDefault";
      runAsNonRoot = true;
      runAsUser = uid;
      runAsGroup = uid;
    };
  };

  # Init container that hands the root-created hostPath volume `data` to `uid`.
  chownData = {
    name = "chown";
    image = "docker.io/library/busybox:1.37.0";
    command = [
      "chown"
      "${toString uid}:${toString uid}"
      "/data"
    ];
    securityContext = {
      runAsNonRoot = false;
      runAsUser = 0;
      runAsGroup = 0;
      allowPrivilegeEscalation = false;
      capabilities = {
        drop = [ "ALL" ];
        add = [ "CHOWN" ];
      };
    };
    volumeMounts = [
      {
        name = "data";
        mountPath = "/data";
      }
    ];
  };
}
