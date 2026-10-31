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

  # OIDC (DISABLED, not wired until clusterNode.oidc.enable = true). Kept
  # from r440's old k8s.nix so it can be switched on later; the issuer still
  # names the old tailnet and needs updating first.
  oidc = cfg.oidc;
  authenticationConfig = (pkgs.formats.yaml { }).generate
    "authentication-config.yaml" {
      apiVersion = "apiserver.config.k8s.io/v1";
      kind = "AuthenticationConfiguration";
      jwt = [
        {
          issuer = {
            url = oidc.issuerUrl;
            audiences = oidc.audiences;
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
          claimValidationRules = [
            {
              message = "token is expired";
              expression =
                "claims.exp > (has(claims.nbf) ? claims.nbf : claims.iat)";
            }
            {
              message = "invalid token signature algorithm";
              expression = "claims.alg in [\"EdDSA\"]";
            }
          ];
        }
      ];
    };
in
{
  options.clusterNode.oidc = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Pass an AuthenticationConfiguration (JWT/OIDC) to kube-apiserver.
        Off: OIDC is not wired yet.
      '';
    };
    issuerUrl = mkOption {
      type = types.str;
      # From r440's old k8s.nix (old tailnet name): update before enabling.
      default = "https://oidc.gaur-dorian.ts.net";
      description = "OIDC issuer URL.";
    };
    audiences = mkOption {
      type = types.listOf types.str;
      default = [ "dcf0a4eb-4c5d-4f7b-a1a0-50aa566eb727" ];
      description = "Accepted token audiences (OIDC client ids).";
    };
  };

  config = lib.mkIf (cfg.enable && lib.elem "controlPlane" node.roles) {
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
        certFile = (leaf "etcd-client-apiserver").cert;
        keyFile = (leaf "etcd-client-apiserver").key;
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
