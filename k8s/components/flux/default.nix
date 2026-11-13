# Flux, namespace `flux-system`: the controllers (install.nix), what they
# reconcile (sync.nix; stages.nix for the deferred components, secrets.nix
# for the sops-encrypted Secrets) and the push
# trigger (receiver.nix). Flux applies the whole render, itself included, so
# it keeps itself up to date and prunes whatever is removed from it.
{ ... }:
{
  imports = [
    ./install.nix
    ./sync.nix
    ./stages.nix
    ./secrets.nix
    ./receiver.nix
  ];

  validation.strict = true;

  resources.core.v1.Namespace.flux-system.metadata.labels = {
    "app.kubernetes.io/part-of" = "flux";
    "pod-security.kubernetes.io/warn" = "restricted";
    "pod-security.kubernetes.io/warn-version" = "latest";
  };
}
