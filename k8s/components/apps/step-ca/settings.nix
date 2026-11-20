# Shared values of apps/step-ca, also read by its flake check (./test) and
# the authentik blueprint ssh-ca.yaml (keep the client ID and groups equal).
rec {
  namespace = "step-ca";
  name = "step-ca";

  # authentik provider (blueprints/ssh-ca.yaml): public client, per-provider issuer.
  clientID = "ssh-ca";
  issuerPath = "/application/o/${clientID}/";

  # authentik groups that may get a certificate; each becomes a principal
  # (only these, never the account's other groups). Hosts map principals
  # to accounts with custom.auth.sshCA.principals.
  sshGroups = [ "ssh-admins" ];

  durations = {
    min = "5m";
    default = "15m";
    max = "1h";
  };

  # step-ca's own HTTPS (internal: only the sidecar talks to it).
  caPort = 9000;
  # The nginx sidecar's HTTPS port (cert from ClusterIssuer cluster-ca).
  port = 443;
  proxyPort = 8443;

  # Secrets: SSH user CA key (sops, k8s/secrets/step-ca/), step-ca's
  # internal X.509 CA and the sidecar's TLS cert (cert-manager).
  userKeySecret = "ssh-user-ca";
  internalCASecret = "step-ca-internal-ca";
  tlsSecret = "step-ca-tls";

  images = {
    stepCa = "docker.io/smallstep/step-ca:0.29.0";
    nginx = "docker.io/nginxinc/nginx-unprivileged:1.31.7-alpine";
  };
}
