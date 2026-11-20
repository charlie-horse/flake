# Names shared by the atcr files (plain data).
rec {
  namespace = "atproto";
  version = "v0.1.4";

  # sops: k8s/secrets/atproto/atcr-secrets.sops.yaml (GARAGE_RPC_SECRET,
  # S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY).
  secretName = "atcr-secrets";
  # kubernetes.io/dockerconfigjson for atcr.io (pulls need an ATProto login):
  # k8s/secrets/atproto/atcr-io-pull.sops.yaml.
  pullSecretName = "atcr-io-pull";

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

  # Container defaults for the root-running scratch images (PSA baseline).
  containerSecurity = {
    allowPrivilegeEscalation = false;
    capabilities.drop = [ "ALL" ];
  };
}
