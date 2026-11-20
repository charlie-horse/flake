# step-ca's X.509 side, all from cert-manager: component
# `apps/step-ca-certificates`, deferred (cert-manager's webhook validates
# every cert-manager.io object).
#
#   Certificate step-ca-internal-ca  self-signed CA (Issuer step-ca-selfsigned)
#                                    that step-ca needs as its root and
#                                    intermediate; only the sidecar trusts it
#   Certificate step-ca-tls          the sidecar's serving cert from
#                                    ClusterIssuer cluster-ca
#
# A CertificateRequestPolicy lets the self-signed Issuer sign that one CA
# and nothing else.
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
  settings = import ./settings.nix;
  inherit (settings) namespace name;
  certManager = import ../../infra/cert-manager/settings.nix;
  crds = import ../../infra/cert-manager/crds.nix {
    inherit
      pkgs
      catenix
      charts
      kubeVersion
      ;
  };

  selfSigned = "${name}-selfsigned";
  caCommonName = "step-ca internal CA";
  caUsages = [
    "cert sign"
    "crl sign"
    "digital signature"
  ];
  caDuration = "8760h";
  ecdsa = {
    algorithm = "ECDSA";
    size = 256;
    rotationPolicy = "Always";
  };
  policyName = "${namespace}-internal-ca";
  policyRole = "cert-manager-policy:${namespace}";
in
{
  imports = [ (catenix.crdModule (crds.certManager ++ crds.approverPolicy)) ];

  validation.strict = true;

  resources."cert-manager.io".v1 = {
    Issuer.${selfSigned} = {
      metadata = { inherit namespace; };
      spec.selfSigned = { };
    };

    Certificate.${settings.internalCASecret} = {
      metadata = { inherit namespace; };
      spec = {
        secretName = settings.internalCASecret;
        isCA = true;
        commonName = caCommonName;
        usages = caUsages;
        duration = caDuration;
        renewBefore = "720h";
        privateKey = ecdsa;
        issuerRef = {
          group = "cert-manager.io";
          kind = "Issuer";
          name = selfSigned;
        };
      };
    };

    Certificate.${settings.tlsSecret} = {
      metadata = { inherit namespace; };
      spec = {
        secretName = settings.tlsSecret;
        dnsNames = [
          "${name}.${namespace}.svc"
          "${name}.${namespace}.svc.cluster.local"
        ];
        ipAddresses = [ cluster.stepCa.serviceIP ];
        duration = "2160h";
        renewBefore = "720h";
        privateKey = ecdsa;
        issuerRef = {
          group = "cert-manager.io";
          kind = "ClusterIssuer";
          name = certManager.caIssuer;
        };
      };
    };
  };

  resources."policy.cert-manager.io".v1alpha1.CertificateRequestPolicy.${policyName}.spec = {
    selector = {
      issuerRef = {
        group = "cert-manager.io";
        kind = "Issuer";
        name = selfSigned;
      };
      namespace.matchNames = [ namespace ];
    };
    allowed = {
      commonName = {
        value = caCommonName;
        required = true;
      };
      isCA = true;
      usages = caUsages;
    };
    constraints = {
      maxDuration = caDuration;
      privateKey = {
        algorithm = "ECDSA";
        minSize = 256;
        maxSize = 256;
      };
    };
  };

  resources."rbac.authorization.k8s.io".v1 = {
    Role.${policyRole} = {
      metadata = { inherit namespace; };
      rules = [
        {
          apiGroups = [ "policy.cert-manager.io" ];
          resources = [ "certificaterequestpolicies" ];
          verbs = [ "use" ];
          resourceNames = [ policyName ];
        }
      ];
    };
    RoleBinding.${policyRole} = {
      metadata = { inherit namespace; };
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
