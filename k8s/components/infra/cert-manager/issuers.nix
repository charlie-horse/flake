# The workload CA issuer, declared: component `infra/cert-manager-issuers`.
#
#   ClusterIssuer `cluster-ca`   CA issuer over the Secret
#                                `cert-manager/cluster-ca`: what workloads
#                                reference
#
# The Secret is not in this component. It comes from
# k8s/secrets/cert-manager/cluster-ca.sops.yaml (made at the root CA
# ceremony, docs/pki-migration-plan.md nodes F and G), and the Flux
# Kustomization `secrets` owns it (prune: true; hand edits are reverted).
# It holds the "neurosis workload CA" intermediate, signed by the YubiKey
# root:
#
#   tls.crt   workload intermediate, then the root (the chain)
#   tls.key   the intermediate's key (made in tmpfs at the ceremony and
#             encrypted with sops straight from there)
#   ca.crt    the root (cluster/pki/root-ca.pem)
#
# No Certificate points at it, so cert-manager does not reissue or renew it.
# Renewal: a new signature from the root, then `sops` edit, PR, merge
# (docs/pki-migration-plan.md "Risks"). Without it the ClusterIssuer is
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
# Approval: cert-manager's auto-approver is off (approver-policy.nix), so
# requests to `cluster-ca` need a CertificateRequestPolicy too:
#
#   CertificateRequestPolicy `cluster-ca`   selects ClusterIssuer cluster-ca
#                                           in every namespace and allows
#                                           any subject, SAN, usage, key and
#                                           duration, but no CA certs (the
#                                           intermediate is pathlen:0). The
#                                           same as the auto-approver did
#   ClusterRole/ClusterRoleBinding          `use` of it for cert-manager's
#   `cert-manager-policy:cluster-ca`        controller (the requester of
#                                           every Certificate's request)
#
# Only the charts' CRDs are read here (crds.nix, to type the objects
# below); the charts themselves are rendered by chart.nix and
# approver-policy.nix.
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
