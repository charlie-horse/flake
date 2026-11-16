# The Kustomization `secrets`: applies the sops-encrypted Secrets
# (k8s/secrets/<namespace>/<name>.sops.yaml, copied verbatim by the render to
# ./deferred/secrets/) from the same signed artifact as `flux-system`, and
# decrypts them in kustomize-controller with the age key in the Secret
# flux-system/sops-age (key `age.agekey`), the one bootstrap secret, made
# once by hand.
#
# Fenced off from `flux-system` like the deferred components (stages.nix):
# a missing key or a bad file fails only this one. prune: removing the last
# file removes this Kustomization and every Secret it applied.
# Docs: docs/k8s/secrets.md
{
  lib,
  deferred,
  ...
}:
{
  resources."kustomize.toolkit.fluxcd.io".v1.Kustomization =
    lib.optionalAttrs deferred.secrets.enable
      {
        ${deferred.secrets.name} = {
          metadata.namespace = "flux-system";
          spec = {
            sourceRef = {
              kind = "OCIRepository";
              name = "flux-system-oci";
            };
            path = "./${deferred.secrets.path}";
            dependsOn = [ { name = "flux-system"; } ];
            interval = "10m";
            retryInterval = "1m";
            timeout = "5m";
            prune = true;
            wait = false;
            decryption = {
              provider = "sops";
              secretRef.name = "sops-age";
            };
          };
        };
      };
}
