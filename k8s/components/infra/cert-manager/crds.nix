# The CRDs of cert-manager and approver-policy, read from their charts (not
# rendered here: chart.nix and approver-policy.nix do that), for the
# components that declare their custom resources (issuers.nix,
# components/infra/cluster-pki):
#
#   imports = [ (catenix.crdModule (crds.certManager ++ crds.approverPolicy)) ];
#
# where crds = import ./crds.nix { inherit pkgs catenix charts kubeVersion; }.
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
  # cert-manager.io: Issuer, ClusterIssuer, Certificate, ...
  certManager = crdsOf charts.cert-manager release;
  # policy.cert-manager.io: CertificateRequestPolicy.
  approverPolicy = crdsOf charts.cert-manager-approver-policy approverPolicyRelease;
}
