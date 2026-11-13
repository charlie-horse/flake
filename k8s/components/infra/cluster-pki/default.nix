# The Issuers are namespaced: whoever may create a Certificate in this
# namespace may ask for a bootstrap cert (bounded by issuers.nix's policies).
{ ... }:
let
  inherit (import ./settings.nix) namespace;
in
{
  # Not deferred: nothing in export.nix goes through cert-manager's webhook.
  imports = [ ./export.nix ];

  validation.strict = true;

  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "pod-security.kubernetes.io/enforce" = "restricted";
    "pod-security.kubernetes.io/warn" = "restricted";
  };
}
