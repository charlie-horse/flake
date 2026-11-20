# step-ca: short-lived OpenSSH user certificates for automations and
# agents, namespace `step-ca`.
#
#   agent --client_credentials--> authentik provider `ssh-ca` (ID token
#   with `groups`) --token--> https://<cluster.stepCa.serviceIP> (nginx
#   sidecar, cluster-ca TLS) --> step-ca (OIDC provisioner `authentik`)
#   --> SSH user cert whose principals are the token's settings.sshGroups
#
#   ca-json.nix     step-ca's config; deployment.nix the pod and Service;
#   certificates.nix (deferred) the X.509 certs from cert-manager;
#   ./test          the flake check `step-ca` (the flow end to end)
#
# The SSH user CA key is the sops Secret step-ca/ssh-user-ca (key `key`);
# hosts trust its public half with custom.auth.sshCA. Docs:
# docs/k8s/apps.md#step-ca
{ ... }:
{
  imports = [ ./deployment.nix ];

  validation.strict = true;

  resources.core.v1.Namespace.step-ca.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "restricted";
    "pod-security.kubernetes.io/warn" = "restricted";
  };
}
