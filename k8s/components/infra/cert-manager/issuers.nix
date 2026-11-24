# The workload CA issuer, declared: component `infra/cert-manager-issuers`.
#
#   ClusterIssuer `cluster-ca`   CA issuer over the Secret
#                                `cert-manager/cluster-ca`: what workloads
#                                reference
#
# The Secret is not in this component: it is sops-encrypted in
# k8s/secrets/cert-manager/cluster-ca.sops.yaml (the "neurosis workload CA"
# intermediate under the YubiKey root) and owned by the Kustomization
# `secrets`. Nothing renews it. Deferred (its own Kustomization, after
# `flux-system`) because cert-manager's webhook validates every
# cert-manager.io object with failurePolicy Fail.
# Contents, renewal and approval: docs/k8s/apps.md#cert-manager
#
# Only the charts' CRDs are read here (crds.nix, to type the objects below).
{
  pkgs,
  catenix,
  charts,
  kubeVersion,
  ...
}:
let
  inherit (import ./settings.nix)
    namespace
    caIssuer
    caSecret
    controllerServiceAccount
    ;

  crds = import ./crds.nix {
    inherit
      pkgs
      catenix
      charts
      kubeVersion
      ;
  };

  any = {
    values = [ "*" ];
  };
  policyRole = "cert-manager-policy:${caIssuer}";
in
{
  imports = [ (catenix.crdModule (crds.certManager ++ crds.approverPolicy)) ];

  validation.strict = true;

  # The Secret lives in cert-manager's cluster resource namespace (the
  # chart's default: the release namespace), where a ClusterIssuer reads it.
  resources."cert-manager.io".v1.ClusterIssuer.${caIssuer}.spec.ca.secretName = caSecret;

  # Allows what cert-manager's built-in approver allows, except CA certs (the intermediate is pathlen:0).
  resources."policy.cert-manager.io".v1alpha1.CertificateRequestPolicy.${caIssuer}.spec = {
    selector.issuerRef = {
      group = "cert-manager.io";
      kind = "ClusterIssuer";
      name = caIssuer;
    };
    allowed = {
      commonName.value = "*";
      dnsNames = any;
      ipAddresses = any;
      uris = any;
      emailAddresses = any;
      subject = {
        organizations = any;
        organizationalUnits = any;
        countries = any;
        localities = any;
        provinces = any;
        streetAddresses = any;
        postalCodes = any;
        serialNumber.value = "*";
      };
      isCA = false;
      usages = [
        "signing"
        "digital signature"
        "content commitment"
        "key encipherment"
        "key agreement"
        "data encipherment"
        "server auth"
        "client auth"
        "code signing"
        "email protection"
        "s/mime"
        "ipsec end system"
        "ipsec tunnel"
        "ipsec user"
        "timestamping"
        "ocsp signing"
      ];
    };
  };

  resources."rbac.authorization.k8s.io".v1 = {
    ClusterRole.${policyRole}.rules = [
      {
        apiGroups = [ "policy.cert-manager.io" ];
        resources = [ "certificaterequestpolicies" ];
        verbs = [ "use" ];
        resourceNames = [ caIssuer ];
      }
    ];
    ClusterRoleBinding.${policyRole} = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = policyRole;
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = controllerServiceAccount;
          inherit namespace;
        }
      ];
    };
  };
}
