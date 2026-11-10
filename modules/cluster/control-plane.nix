# kube-apiserver, kube-controller-manager and kube-scheduler on nodes with
# the "controlPlane" role. Every controlPlane node runs all three; the
# controller-manager and scheduler use leader election, and talk to their
# local apiserver. Authorization is Node,RBAC (no AlwaysAllow).
{ config, lib, pkgs, cluster, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.clusterNode;
  node = cfg.node;
  k8s = config.services.kubernetes;
  port = toString cluster.apiserverPort;
  local = "https://127.0.0.1:${port}";
  secret = cfg.secret;
  leaf = cfg.leaf;
  etcdClient = if cfg.etcd.phase == "final"
    then "etcd-client-apiserver" else "legacy-etcd-client-apiserver";

  etcdNodes = lib.filter (n: lib.elem "etcd" cluster.nodes.${n}.roles)
    (lib.attrNames cluster.nodes);
  # Local member first, then the others.
  etcdServers = map (n: "https://${n}:2379")
    (lib.optional (lib.elem cfg.name etcdNodes) cfg.name
      ++ lib.remove cfg.name etcdNodes);

  kubeconfig = name: component:
    k8s.lib.mkKubeConfig name {
      server = local;
      caFile = secret "ca.pem";
      certFile = (leaf component).cert;
      keyFile = (leaf component).key;
    };
  controllerManagerKubeconfig =
    kubeconfig "kube-controller-manager" "controller-manager";
  schedulerKubeconfig = kubeconfig "kube-scheduler" "scheduler";

  # OIDC (on when cluster/definition.nix has `oidc`): authentik's provider
  # `kubernetes` (blueprint in k8s/components/authentik.nix). Usernames and
  # groups are prefixed `oidc:`, so a token can never claim a built-in
  # identity (system:masters, system:nodes, ...); RBAC binds
  # oidc:cluster-admins (k8s/components/rbac.nix). x509 client certs and
  # service-account tokens never depend on the issuer: if authentik is down
  # only OIDC logins fail, and the admin cert is the break-glass.
  #
  # One JWT authenticator per issuer: the main one (issuerUrl/audiences) plus
  # extraIssuers. authentik's issuer is per provider, so every OIDC client
  # (kubernetes for kubectl, headlamp for Headlamp) is its own issuer. The
  # claim mappings are the same for all of them.
  oidc = cfg.oidc;
  jwtAuthenticator = { issuerUrl, audiences }:
    {
      issuer = {
        url = issuerUrl;
        inherit audiences;
      } // lib.optionalAttrs (oidc.certificateAuthority != null) {
        inherit (oidc) certificateAuthority;
      };
      claimMappings = {
        uid.claim = "sub";
        username = {
          claim = "preferred_username";
          prefix = "oidc:";
        };
        groups = {
          claim = "groups";
          prefix = "oidc:";
        };
      };
      # (The signature algorithm is a JOSE header, not a claim: CEL
      # cannot see it. The apiserver accepts the asymmetric algorithms
      # of the issuer's JWKS; authentik signs RS256 with its
      # self-signed key pair.)
      claimValidationRules = [
        {
          message = "token is expired";
          expression =
            "claims.exp > (has(claims.nbf) ? claims.nbf : claims.iat)";
        }
      ];
    };
  authenticationConfig = (pkgs.formats.yaml { }).generate
    "authentication-config.yaml" {
      apiVersion = "apiserver.config.k8s.io/v1";
      kind = "AuthenticationConfiguration";
      jwt = map jwtAuthenticator ([
        { inherit (oidc) issuerUrl audiences; }
      ] ++ oidc.extraIssuers);
    };
in
{
  options.clusterNode.oidc = {
    enable = mkOption {
      type = types.bool;
      default = cluster ? oidc;
      defaultText = "whether cluster/definition.nix has `oidc`";
      description = ''
        Pass an AuthenticationConfiguration (JWT/OIDC) to kube-apiserver.
        Needs issuerUrl.
      '';
    };
    issuerUrl = mkOption {
      type = types.nullOr types.str;
      default = cluster.oidc.issuerUrl or null;
      defaultText = "cluster.oidc.issuerUrl or null";
      example = "https://auth.example.org/application/o/kubernetes/";
      description = ''
        OIDC issuer URL, byte for byte the `iss` of the tokens. authentik's
        per-provider issuer is https://<host>/application/o/<slug>/ (with
        the trailing slash). The apiserver fetches its discovery document
        and JWKS over HTTPS.
      '';
    };
    audiences = mkOption {
      type = types.listOf types.str;
      default = cluster.oidc.audiences or [ "kubernetes" ];
      defaultText = "cluster.oidc.audiences or [ \"kubernetes\" ]";
      description = "Accepted token audiences (OIDC client ids).";
    };
    extraIssuers = mkOption {
      type = types.listOf (types.submodule {
        options = {
          issuerUrl = mkOption {
            type = types.str;
            description = "Issuer URL, byte for byte the tokens' `iss`.";
          };
          audiences = mkOption {
            type = types.listOf types.str;
            description = "Accepted audiences (client ids) for this issuer.";
          };
        };
      });
      default = cluster.oidc.extraIssuers or [ ];
      defaultText = "cluster.oidc.extraIssuers or [ ]";
      description = ''
        More JWT authenticators with the same claim mappings (`oidc:`
        prefixes), one per issuer, e.g. authentik's provider `headlamp`.
        Issuer URLs must all differ from each other and from issuerUrl.
      '';
    };
    certificateAuthority = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        PEM CA bundle for the issuer's TLS certificate. null: the system
        roots (enough for a publicly trusted certificate).
      '';
    };
  };

  config = lib.mkIf (cfg.enable && lib.elem "controlPlane" cfg.activeRoles) {
    assertions = [
      {
        assertion = oidc.enable -> oidc.issuerUrl != null;
        message = "clusterNode.oidc.enable needs clusterNode.oidc.issuerUrl.";
      }
    ];

    services.kubernetes.apiserver = {
      enable = true;
      advertiseAddress = node.lanIP;
      bindAddress = "0.0.0.0";
      # The flannel and NVIDIA device-plugin DaemonSets run privileged.
      allowPrivileged = true;
      securePort = cluster.apiserverPort;
      serviceClusterIpRange = cluster.serviceCidr;
      authorizationMode = [ "Node" "RBAC" ];
      # The kubelets' InternalIP is their LAN IP (--node-ip), which their
      # serving certs carry as a SAN; hostname (MagicDNS) as fallback.
      preferredAddressTypes = "InternalIP,Hostname,InternalDNS,ExternalDNS";
      runtimeConfig = "api/all=true";

      clientCaFile = secret "ca.pem";
      tlsCertFile = (leaf "apiserver").cert;
      tlsKeyFile = (leaf "apiserver").key;

      serviceAccountKeyFile = secret "sa.pub";
      serviceAccountSigningKeyFile = secret "sa.key";

      kubeletClientCaFile = secret "ca.pem";
      kubeletClientCertFile = (leaf "apiserver-kubelet-client").cert;
      kubeletClientKeyFile = (leaf "apiserver-kubelet-client").key;

      proxyClientCertFile = (leaf "front-proxy-client").cert;
      proxyClientKeyFile = (leaf "front-proxy-client").key;

      etcd = {
        servers = etcdServers;
        caFile = secret "etcd-ca.pem";
        # "trust" phase: the legacy client cert (tls/apiserver/etcd-client,
        # ETCD CA 1), which the not-yet-switched members accept.
        certFile = (leaf etcdClient).cert;
        keyFile = (leaf etcdClient).key;
      };

      extraOpts = lib.concatStringsSep " " ([
        # Aggregation layer (metrics-server etc.): front-proxy CA + headers.
        "--requestheader-client-ca-file=${secret "front-proxy-ca.pem"}"
        "--requestheader-allowed-names=front-proxy-client"
        "--requestheader-username-headers=X-Remote-User"
        "--requestheader-group-headers=X-Remote-Group"
        "--requestheader-extra-headers-prefix=X-Remote-Extra-"
        # One "kubernetes" Endpoints entry per apiserver, kept by lease.
        "--endpoint-reconciler-type=lease"
      ] ++ lib.optional oidc.enable
        "--authentication-config=${authenticationConfig}");
    };

    services.kubernetes.controllerManager = {
      enable = true;
      leaderElect = true;
      securePort = 10257;
      bindAddress = "127.0.0.1";
      allocateNodeCIDRs = true;
      clusterCidr = cluster.podCidr;
      rootCaFile = secret "ca.pem";
      serviceAccountKeyFile = secret "sa.key";
      kubeconfig = {
        server = local;
        caFile = secret "ca.pem";
        certFile = (leaf "controller-manager").cert;
        keyFile = (leaf "controller-manager").key;
      };
      extraOpts = lib.concatStringsSep " " [
        "--service-cluster-ip-range=${cluster.serviceCidr}"
        "--node-cidr-mask-size=${toString cluster.nodeCidrMaskSize}"
        "--cluster-name=${cluster.name}"
        "--authentication-kubeconfig=${controllerManagerKubeconfig}"
        "--authorization-kubeconfig=${controllerManagerKubeconfig}"
        # No --cluster-signing-*: the CA key never leaves the operator
        # machine, so the CSR signer is off (static kubelet certs).
      ];
    };

    services.kubernetes.scheduler = {
      enable = true;
      leaderElect = true;
      port = 10259;
      address = "127.0.0.1";
      kubeconfig = {
        server = local;
        caFile = secret "ca.pem";
        certFile = (leaf "scheduler").cert;
        keyFile = (leaf "scheduler").key;
      };
      extraOpts = lib.concatStringsSep " " [
        "--authentication-kubeconfig=${schedulerKubeconfig}"
        "--authorization-kubeconfig=${schedulerKubeconfig}"
      ];
    };
    # Until `cluster-pki deploy` has put the certs in place the units fail
    # and retry (NixOS sets Restart=on-failure and no start limit).
  };
}
