# Push trigger: render.yml POSTs here (HMAC-signed with the token) right
# after pushing a new artifact, so Flux fetches it at once instead of at the
# next poll. Reached through the tunnel at https://<cluster.fluxWebhook.host>
# /hook/<path> (apps/cloudflared lets only /hook/ through for that host).
#
# The token is NOT in git: Secret flux-system/webhook-token, key `token`,
# made by hand without a trailing newline (it is the HMAC key verbatim, and
# the webhook path is derived from it: see k8s/README.md).
{ ... }:
{
  resources."notification.toolkit.fluxcd.io".v1.Receiver.ghcr = {
    metadata.namespace = "flux-system";
    spec = {
      type = "generic-hmac";
      secretRef.name = "webhook-token";
      resources = [
        {
          apiVersion = "source.toolkit.fluxcd.io/v1";
          kind = "OCIRepository";
          name = "flux-system-oci";
        }
      ];
    };
  };
}
