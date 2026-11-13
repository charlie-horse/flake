{
  pkgs,
  catenix,
  charts,
  kubeVersion,
}:
let
  inherit (import ./settings.nix) release approverPolicyRelease;

  crdsOf =
    chart: release:
    builtins.filter (m: m.kind or null == "CustomResourceDefinition") (
      builtins.fromJSON (
        builtins.readFile (
          catenix.helmTemplate pkgs {
            inherit kubeVersion release chart;
            values.crds.enabled = true;
          }
        )
      )
    );
in
{
  certManager = crdsOf charts.cert-manager release;
  approverPolicy = crdsOf charts.cert-manager-approver-policy approverPolicyRelease;
}
