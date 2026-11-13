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

  # approver-policy denies any field the policy leaves out.
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

  # One per leaf: a policy allows CN and O independently, so a per-Issuer
  # policy could not tie system:masters to cluster-admin.
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
