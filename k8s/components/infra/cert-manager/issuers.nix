# The workload CA issuer, declared: component `infra/cert-manager-issuers`.
#
#   ClusterIssuer `cluster-ca`   CA issuer over the Secret
#                                `cert-manager/cluster-ca`: what workloads
#                                reference
#
# The Secret is NOT declared here or anywhere in git: it is created by hand
# (docs/pki-migration-plan.md, nodes F and G). It holds the "neurosis
# workload CA" intermediate, signed by the YubiKey root:
#
#   tls.crt   workload intermediate, then the root (the chain)
#   tls.key   the intermediate's key (made in tmpfs at the ceremony, handed
#             straight to `kubectl create secret`, never copied anywhere)
#   ca.crt    the root (cluster/pki/root-ca.pem)
#
# Flux never touches it: it is in no Kustomization's inventory, so it is
# neither pruned nor overwritten, and with no Certificate pointing at it
# cert-manager does not reissue or renew it either (renewal is manual,
# docs/pki-migration-plan.md "Risks"). Until it exists the ClusterIssuer is
# NotReady, and so is this Kustomization (`wait`); nothing else is affected.
#
# Applied by its own Flux Kustomization `cert-manager-issuers`
# (components/flux/stages.nix), after `flux-system` has applied the same
# revision. cert-manager's webhook validates every cert-manager.io object
# with failurePolicy Fail, server-side dry runs included: in `flux-system`
# these objects would make the whole cluster's apply fail whenever the
# webhook is down, the fix for the webhook included. Here only this
# Kustomization fails, and retries.
#
# Only the chart's CRDs are read here (to type the objects below); the chart
# itself is rendered by chart.nix.
{
  pkgs,
  catenix,
  charts,
  kubeVersion,
  ...
}:
let
  inherit (import ./settings.nix)
    release
    caIssuer
    caSecret
    ;

  crds = builtins.filter (m: m.kind or null == "CustomResourceDefinition") (
    builtins.fromJSON (
      builtins.readFile (
        catenix.helmTemplate pkgs {
          inherit kubeVersion release;
          chart = charts.cert-manager;
          values.crds.enabled = true;
        }
      )
    )
  );
in
{
  imports = [ (catenix.crdModule crds) ];

  validation.strict = true;

  # The Secret lives in cert-manager's cluster resource namespace (the
  # chart's default: the release namespace), where a ClusterIssuer reads it.
  resources."cert-manager.io".v1.ClusterIssuer.${caIssuer}.spec.ca.secretName = caSecret;
}
