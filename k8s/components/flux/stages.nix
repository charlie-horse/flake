# One Kustomization per deferred component (k8s/default.nix `deferred`),
# named after the component's last path element (infra/cert-manager-issuers
# -> cert-manager-issuers), from the same signed artifact as `flux-system`.
#
# Deferred components render under ./deferred/, which holds an empty
# kustomization.yaml, so `flux-system` (path ./) leaves that subtree out:
# Flux's generator takes a directory with a kustomization.yaml as a base and
# does not look inside it. Each Kustomization here builds its own
# directory below it instead.
#
# They are for objects whose apply needs something `flux-system` deploys to
# be running first, typically an admission webhook with failurePolicy Fail
# (cert-manager's: every cert-manager.io object). Kept out of `flux-system`,
# a down webhook fails only that Kustomization, not the apply of the whole
# cluster (Flux dry-runs every object before applying any; one failure
# applies nothing).
#
#   dependsOn flux-system   starts once `flux-system` has applied the same
#                           revision of the artifact (CRDs, the webhook's
#                           Deployment)
#   retryInterval 1m        until the webhook answers (first install)
#   wait                    Ready only when every object is Ready (the
#                           ClusterIssuers, the root Certificate)
{
  lib,
  deferred,
  ...
}:
{
  resources."kustomize.toolkit.fluxcd.io".v1.Kustomization = lib.listToAttrs (
    map (
      component:
      lib.nameValuePair (baseNameOf component) {
        metadata.namespace = "flux-system";
        spec = {
          sourceRef = {
            kind = "OCIRepository";
            name = "flux-system-oci";
          };
          path = "./${deferred.dir}/${component}";
          dependsOn = [ { name = "flux-system"; } ];
          interval = "10m";
          retryInterval = "1m";
          timeout = "5m";
          prune = true;
          wait = true;
        };
      }
    ) deferred.components
  );
}
