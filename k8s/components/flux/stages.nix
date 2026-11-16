# One Kustomization per deferred component (k8s/default.nix `deferred`),
# named after the component's last path element (infra/cert-manager-issuers
# -> cert-manager-issuers), from the same signed artifact as `flux-system`.
# ./deferred/ holds an empty kustomization.yaml, so `flux-system` (path ./)
# skips the subtree; each Kustomization here builds its own directory.
#
#   dependsOn flux-system   after `flux-system` applied the same revision
#                           (CRDs, the webhook's Deployment)
#   retryInterval 1m        until the webhook answers (first install)
#   wait                    Ready only when every object is Ready
#
# Why (admission webhooks with failurePolicy Fail): docs/k8s/README.md#deferred-components
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
