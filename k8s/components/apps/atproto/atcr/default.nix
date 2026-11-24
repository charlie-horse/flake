# ATCR (ATProto container registry, upstream
# tangled.org/evan.jarrett.net/at-container-registry), namespace `atproto`:
#
#   appview.nix  AppView: registry API and web UI (cluster.atcr.host)
#   hold.nix     hold: blob service (cluster.atcrHold.host)
#   garage.nix   Garage: the hold's S3 store
#
# State in node-local volumes under /var/lib/atcr. AppView and hold
# images: settings.nix;
# Secret atproto/atcr-secrets (sops). Operating it: docs/k8s/apps.md#atcr
{ ... }:
{
  imports = [
    ./appview.nix
    ./hold.nix
    ./garage.nix
  ];

  validation.strict = true;
}
