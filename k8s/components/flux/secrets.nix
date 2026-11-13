# The Kustomization `secrets`: applies the sops-encrypted Secrets
# (k8s/secrets/<namespace>/<name>.sops.yaml, copied verbatim by the render to
# ./deferred/secrets/) from the same signed artifact as `flux-system`, and
# decrypts them in kustomize-controller with the age key in the Secret
# flux-system/sops-age (key `age.agekey`). That Secret is the one bootstrap
# secret, made once by hand (k8s/README.md, "Secrets").
#
# A Kustomization of its own, fenced off from `flux-system` like the deferred
# components (stages.nix): a missing sops-age, a file encrypted to the
# wrong key or a broken MAC fails only this one, never the apply of the rest
# of the cluster (and `flux-system` never needs the key).
#
#   dependsOn flux-system   the namespaces exist first
#   prune                   a Secret whose file is removed is deleted;
#                           removing the last file removes this
#                           Kustomization and with it every Secret it applied
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
