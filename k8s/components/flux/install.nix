# Flux v2 controllers and CRDs (fluxcd-community flux2 chart):
# source-, kustomize-, helm- and notification-controller. The
# image-automation/-reflector controllers are off (nothing writes to git
# from the cluster), as is the chart's pre-install `flux check` Job (a Helm
# hook; Flux here is applied by kubectl, then by itself). Importing the
# chart also types the Flux custom resources in sync.nix and receiver.nix.
# All controller images (ghcr.io/fluxcd/*) are multi-arch.
{
  pkgs,
  catenix,
  charts,
  cluster,
  kubeVersion,
  k8sLib,
  ...
}:
{
  imports = [
    (catenix.importChart {
      inherit pkgs kubeVersion;
      chart = charts.flux2;
      release = {
        name = "flux2";
        namespace = "flux-system";
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
      # The webhook receiver is reached through the tunnel at a fixed IP
      # (cluster.fluxWebhook, apps/cloudflared).
      patch = k8sLib.fixedServiceIP {
        service = "webhook-receiver";
        ip = cluster.fluxWebhook.serviceIP;
      };
      noHooks = true;
    })
  ];
}
