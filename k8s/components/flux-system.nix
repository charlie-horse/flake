# Flux v2 controllers and CRDs (fluxcd-community flux2 chart) in
# flux-system: source-, kustomize-, helm- and notification-controller.
# The image-automation/-reflector controllers are off (nothing writes to
# git from the cluster), as is the chart's pre-install `flux check` Job
# (a Helm hook; Flux here is applied by kubectl and then by itself).
# All controller images (ghcr.io/fluxcd/*) are multi-arch (amd64, arm64).
#
# The GitRepository/Kustomization that make Flux reconcile this repo are
# 50-flux-sync (flux-sync.nix), a separate file so a fresh
# `kubectl apply -f k8s/rendered/` creates these CRDs first.
{
  lib,
  pkgs,
  catenix,
  charts,
  cluster,
  kubeVersion,
  ...
}:
let
  namespace = "flux-system";
in
{
  imports = [
    (catenix.importChart {
      inherit pkgs kubeVersion;
      chart = charts.flux2;
      release = {
        name = "flux2";
        inherit namespace;
      };
      values = {
        clusterDomain = cluster.clusterDomain;
        imageAutomationController.create = false;
        imageReflectionController.create = false;
        # Keyless cosign (OCIRepository verify) caches Sigstore's TUF trust
        # root under $HOME/.sigstore; HOME is / on a read-only root fs. Use
        # the writable /tmp emptyDir, as upstream Flux's own manifests do.
        sourceController.extraEnv = [
          {
            name = "TUF_ROOT";
            value = "/tmp/.sigstore";
          }
        ];
      };
      patch = manifest:
      if manifest.kind == "Service" && manifest.metadata.name == "webhook-receiver"
      then lib.recursiveUpdate manifest {
        metadata.annotations."kustomize.toolkit.fluxcd.io/force" = "enabled";
        spec.clusterIP = cluster.fluxWebhook.serviceIP;
      } else manifest;
      noHooks = true;
    })
  ];

  validation.strict = true;

  resources.core.v1.Namespace.${namespace}.metadata.labels = {
    "app.kubernetes.io/part-of" = "flux";
    "pod-security.kubernetes.io/warn" = "restricted";
    "pod-security.kubernetes.io/warn-version" = "latest";
  };
}
