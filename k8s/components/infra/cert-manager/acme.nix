# Public (Let's Encrypt) issuers, declared: component
# `infra/cert-manager-acme`, deferred like issuers.nix.
#
#   ClusterIssuer `letsencrypt-staging`     untrusted test certificates
#   ClusterIssuer `letsencrypt-production`  publicly trusted certificates
#
# ACME DNS-01 through Cloudflare for `acmeZone` only, with the token from
# the Secret `cert-manager/cloudflare-api-token` (sops, owned by the
# Kustomization `secrets`). cert-manager makes each ACME account key itself
# (Secret `cert-manager/<issuer>-account`). One CertificateRequestPolicy per
# issuer allows only DNS names in `acmeZone`.
# Docs: docs/k8s/apps.md#public-certificates-lets-encrypt
{
  lib,
  pkgs,
  catenix,
  charts,
  kubeVersion,
  ...
}:
let
  inherit (import ./settings.nix)
    namespace
    controllerServiceAccount
    acmeIssuers
    acmeZone
    cloudflareTokenSecret
    cloudflareTokenKey
    ;

  crds = import ./crds.nix {
    inherit
      pkgs
      catenix
      charts
      kubeVersion
      ;
  };

  names = lib.attrNames acmeIssuers;
  policyRole = "cert-manager-policy:acme";

  issuer = name: server: {
    spec.acme = {
      inherit server;
      privateKeySecretRef.name = "${name}-account";
      solvers = [
        {
          selector.dnsZones = [ acmeZone ];
          dns01.cloudflare.apiTokenSecretRef = {
            name = cloudflareTokenSecret;
            key = cloudflareTokenKey;
          };
        }
      ];
    };
  };

  # approver-policy denies any field the policy leaves out (so no
  # commonName, IPs, URIs or subject); "*" matches any string, dots included.
  policy = name: {
    spec = {
      selector.issuerRef = {
        group = "cert-manager.io";
        kind = "ClusterIssuer";
        inherit name;
      };
      allowed = {
        dnsNames = {
          values = [
            acmeZone
            "*.${acmeZone}"
          ];
          required = true;
        };
        usages = [
          "digital signature"
          "key encipherment"
          "server auth"
        ];
      };
    };
  };
in
{
  imports = [ (catenix.crdModule (crds.certManager ++ crds.approverPolicy)) ];

  validation.strict = true;

  resources."cert-manager.io".v1.ClusterIssuer = lib.mapAttrs issuer acmeIssuers;

  resources."policy.cert-manager.io".v1alpha1.CertificateRequestPolicy = lib.genAttrs names policy;

  resources."rbac.authorization.k8s.io".v1 = {
    ClusterRole.${policyRole}.rules = [
      {
        apiGroups = [ "policy.cert-manager.io" ];
        resources = [ "certificaterequestpolicies" ];
        verbs = [ "use" ];
        resourceNames = names;
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
