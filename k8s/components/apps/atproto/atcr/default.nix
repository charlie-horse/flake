# ATCR (ATProto container registry, upstream
# tangled.org/evan.jarrett.net/at-container-registry), namespace `atproto`:
#
#   appview.nix  AppView: registry API and web UI, https://cr.neuros.is
#   hold.nix     hold: blob service, https://hold.neuros.is
#   garage.nix   Garage: the hold's S3 store
#
# Everything on r440 (hostPath PVs under /var/lib/atcr). Images from
# atcr.io (pull Secret atproto/atcr-io-pull); Secret
# atproto/atcr-secrets (sops). Operating it: docs/k8s/apps.md#atcr
{ ... }:
{
  imports = [
    ./appview.nix
    ./hold.nix
    ./garage.nix
  ];

  validation.strict = true;
}
