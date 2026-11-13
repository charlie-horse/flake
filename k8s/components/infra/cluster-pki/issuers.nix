# The bootstrap CAs as cert-manager Issuers, and every bootstrap leaf as a
# Certificate: component `infra/cluster-pki-issuers` (deferred; its own
# Flux Kustomization `cluster-pki-issuers`, components/flux/stages.nix).
# docs/pki-migration-plan.md, phase 2, node P1.
#
#   Issuer k8s-ca, etcd-ca, front-proxy-ca
#       CA issuers over the Secrets of the same names in `cluster-pki`
#       (kubernetes.io/tls: tls.crt = the intermediate, cluster/pki/<name>.pem;
#       tls.key; ca.crt = the root). They come from
#       k8s/secrets/cluster-pki/<name>.sops.yaml (Kustomization `secrets`).
#       Until those exist the Issuers, the Certificates and this
#       Kustomization are NotReady; nothing else is affected.
#
#   Certificate <component>-<node>   (= its Secret)
#       one per leaf cluster-pki makes (leaves.nix): same CN, O, DNS and IP
#       SANs and key usages, RSA 2048 (PKCS#1, a new key at every
#       renewal), 8760h, renewed 720h before expiry. Labels
#       pki.neurosis/node and pki.neurosis/ca, on the Secret too. The
#       Secret's tls.crt is the leaf then the intermediate (cluster-pki
#       appends the intermediate only to server and peer leaves).
#
#   CertificateRequestPolicy cluster-pki-<component>-<node>
#       one per leaf, selecting its Issuer in this namespace and allowing
#       exactly that leaf: the CN (required), the O (required when the leaf
#       has one, none otherwise), only its DNS and IP SANs, only its
#       usages, RSA 2048, at most 8760h, no CA. Every other field (URIs,
#       emails, OU, other subject fields, isCA) is denied. So the k8s CA
#       signs O=system:masters only with CN=cluster-admin and
#       system:node:<n> (O=system:nodes) only for the nodes in
#       cluster/definition.nix, each with its own SANs. One policy per leaf,
#       not per Issuer: a policy allows one CN and a set of O values
#       independently, so a single per-Issuer policy could not tie
#       system:masters to cluster-admin.
#
#   Role/RoleBinding cert-manager-policy:cluster-pki
#       `use` of exactly those policies, in this namespace, for
#       cert-manager's controller (the requester of every Certificate's
#       CertificateRequest).
#
# Changing a leaf (cluster/definition.nix, e.g. apiserverExtraSANs) changes
# its Certificate and its policy in the same render: cert-manager reissues
# it, and the export job brings it to the hosts.
{
  lib,
  pkgs,
  catenix,
  charts,
  kubeVersion,
  cluster,
  ...
}:
let
  inherit (import ./settings.nix)
    namespace
    issuers
    keySize
    duration
    renewBefore
    labelNode
    labelCA
    ;
  certManager = import ../cert-manager/settings.nix;

  crds = import ../cert-manager/crds.nix {
    inherit
      pkgs
      catenix
      charts
      kubeVersion
      ;
  };

  leaves = import ./leaves.nix { inherit lib cluster; };

  labels = l: {
    ${labelNode} = l.node;
    ${labelCA} = l.ca;
  };

  issuerRef = l: {
    group = "cert-manager.io";
    kind = "Issuer";
    name = issuers.${l.ca};
  };

  policyName = l: "cluster-pki-${l.name}";
  policyRole = "cert-manager-policy:${namespace}";

  # `values` + `required`, or nothing (= none allowed) for an empty list.
  exactly =
    values:
    lib.optionalAttrs (values != [ ]) {
      inherit values;
      required = true;
    };

  certificate = l: {
    metadata = {
      inherit namespace;
      labels = labels l;
    };
    spec = {
      secretName = l.name;
      secretTemplate.labels = labels l;
      inherit (l) commonName usages;
      inherit duration renewBefore;
      privateKey = {
        algorithm = "RSA";
        size = keySize;
        encoding = "PKCS1";
        rotationPolicy = "Always";
      };
      issuerRef = issuerRef l;
    }
    // lib.optionalAttrs (l.organizations != [ ]) { subject.organizations = l.organizations; }
    // lib.optionalAttrs (l.dnsNames != [ ]) { inherit (l) dnsNames; }
    // lib.optionalAttrs (l.ipAddresses != [ ]) { inherit (l) ipAddresses; };
  };

  policy = l: {
    metadata.labels = labels l;
    spec = {
      selector = {
        issuerRef = issuerRef l;
        namespace.matchNames = [ namespace ];
      };
      allowed = {
        commonName = {
          value = l.commonName;
          required = true;
        };
        isCA = false;
        inherit (l) usages;
      }
      // lib.optionalAttrs (l.organizations != [ ]) { subject.organizations = exactly l.organizations; }
      // lib.optionalAttrs (l.dnsNames != [ ]) { dnsNames = exactly l.dnsNames; }
      // lib.optionalAttrs (l.ipAddresses != [ ]) { ipAddresses = exactly l.ipAddresses; };
      constraints = {
        maxDuration = duration;
        privateKey = {
          algorithm = "RSA";
          minSize = keySize;
          maxSize = keySize;
        };
      };
    };
  };

  byName = f: lib.listToAttrs (map (l: lib.nameValuePair l.name (f l)) leaves);
in
# approver-policy matches values with "*" as a wildcard: no leaf value may
# contain one, or its policy would allow more than that leaf.
assert lib.assertMsg (
  !lib.any (
    l: lib.any (lib.hasInfix "*") ([ l.commonName ] ++ l.organizations ++ l.dnsNames ++ l.ipAddresses)
  ) leaves
) "cluster-pki: a leaf value contains '*' (a wildcard in CertificateRequestPolicy)";
{
  imports = [ (catenix.crdModule (crds.certManager ++ crds.approverPolicy)) ];

  validation.strict = true;

  resources."cert-manager.io".v1 = {
    Issuer = lib.mapAttrs' (
      _: name:
      lib.nameValuePair name {
        metadata.namespace = namespace;
        spec.ca.secretName = name;
      }
    ) issuers;

    Certificate = byName certificate;
  };

  resources."policy.cert-manager.io".v1alpha1.CertificateRequestPolicy = lib.mapAttrs' (
    _: l: lib.nameValuePair (policyName l) (policy l)
  ) (byName (l: l));

  resources."rbac.authorization.k8s.io".v1 = {
    Role.${policyRole} = {
      metadata.namespace = namespace;
      rules = [
        {
          apiGroups = [ "policy.cert-manager.io" ];
          resources = [ "certificaterequestpolicies" ];
          verbs = [ "use" ];
          resourceNames = map policyName leaves;
        }
      ];
    };
    RoleBinding.${policyRole} = {
      metadata.namespace = namespace;
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = policyRole;
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = certManager.controllerServiceAccount;
          inherit (certManager) namespace;
        }
      ];
    };
  };
}
