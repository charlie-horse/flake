# docs/pki.md, "Phase 2 operations"
{
  config,
  lib,
  inputs,
  cluster,
  ...
}:
let
  cfg = config.clusterNode;
  name = cfg.name;

  # By roles, not rollout stage: the set the export job writes to secrets/pki/<node>.yaml.
  leaves = map (l: l.component) (
    lib.filter (l: l.node == name) (
      import ../../k8s/components/infra/cluster-pki/leaves.nix { inherit lib cluster; }
    )
  );

  hasEtcd = lib.elem "etcd" cfg.node.roles;
  hasCP = lib.elem "controlPlane" cfg.node.roles;

  # Each key belongs to the user of the unit that reads it.
  keyOwner =
    component:
    if
      lib.elem component [
        "etcd-peer"
        "etcd-server"
      ]
    then
      "etcd"
    else if
      lib.elem component [
        "kubelet"
        "kube-proxy"
        "flannel"
        "admin"
      ]
    then
      "root"
    else
      "kubernetes";

  componentUnits = {
    etcd-peer = [ "etcd" ];
    etcd-server = [ "etcd" ];
    etcd-client-apiserver = [ "kube-apiserver" ];
    apiserver = [ "kube-apiserver" ];
    apiserver-kubelet-client = [ "kube-apiserver" ];
    front-proxy-client = [ "kube-apiserver" ];
    controller-manager = [ "kube-controller-manager" ];
    scheduler = [ "kube-scheduler" ];
    kubelet = [ "kubelet" ];
    kube-proxy = [ "kube-proxy" ];
  };
  units =
    us:
    map (u: "${u}.service") (
      lib.filter (u: config.systemd.services ? ${u} && config.systemd.services.${u}.enable) us
    );

  # Only this file goes to the store, not the flake source
  # (modules/system/sops.nix, header).
  pkiSopsPath = "${inputs.self}/secrets/pki/${name}.yaml";
  pkiSopsExists = builtins.pathExists pkiSopsPath;
  pkiSopsFile =
    if pkiSopsExists then
      builtins.path {
        path = pkiSopsPath;
        name = "pki-${name}.yaml";
      }
    else
      pkiSopsPath;
  saSopsFile = builtins.path {
    path = "${inputs.self}/secrets/cluster-sa.yaml";
    name = "cluster-sa.yaml";
  };

  secret =
    {
      file,
      owner,
      restart,
      sopsFile ? pkiSopsFile,
    }:
    lib.nameValuePair "pki/${file}" {
      inherit sopsFile owner;
      group = owner;
      mode = if lib.hasSuffix "-key.pem" file || file == "sa.key" then "0600" else "0644";
      key = file;
      path = cfg.secret file;
      restartUnits = units restart;
    };

  leafSecrets = lib.concatMap (
    c:
    let
      restart = componentUnits.${c} or [ ];
    in
    [
      (secret {
        file = "${c}-${name}.pem";
        owner = "root";
        inherit restart;
      })
      (secret {
        file = "${c}-${name}-key.pem";
        owner = keyOwner c;
        inherit restart;
      })
    ]
  ) leaves;

  # Static and identical on every control plane.
  saSecrets = lib.optionals hasCP [
    (secret {
      file = "sa.pub";
      owner = "root";
      restart = [ "kube-apiserver" ];
      sopsFile = saSopsFile;
    })
    (secret {
      file = "sa.key";
      owner = "kubernetes";
      restart = [
        "kube-apiserver"
        "kube-controller-manager"
      ];
      sopsFile = saSopsFile;
    })
  ];

  # Public trust bundles (intermediate only, the anchor rule) from git.
  bundle =
    file: src: restart:
    lib.nameValuePair "pki/${file}" {
      file = src;
      path = cfg.secret file;
      owner = "root";
      group = "root";
      mode = "0644";
      restartUnits = units restart;
    };
  bundles = [
    (bundle "ca.pem" ../../cluster/pki/k8s-ca.pem [
      "kube-apiserver"
      "kube-controller-manager"
      "kube-scheduler"
      "kubelet"
      "kube-proxy"
    ])
  ]
  ++ lib.optional (hasEtcd || hasCP) (
    bundle "etcd-ca.pem" ../../cluster/pki/etcd-ca.pem [
      "etcd"
      "kube-apiserver"
    ]
  )
  ++ lib.optional hasCP (
    bundle "front-proxy-ca.pem" ../../cluster/pki/front-proxy-ca.pem [ "kube-apiserver" ]
  );

  owners = lib.unique (map (s: s.value.owner) (leafSecrets ++ saSecrets));

  # Root-only break-glass (works without authentik); file paths only, nothing secret in the store.
  adminKubeconfig = config.services.kubernetes.lib.mkKubeConfig "cluster-admin" {
    server = config.services.kubernetes.apiserverAddress;
    caFile = cfg.secret "ca.pem";
    certFile = (cfg.leaf "admin").cert;
    keyFile = (cfg.leaf "admin").key;
  };
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkiSopsExists;
        message = ''
          clusterNode: secrets/pki/${name}.yaml does not exist (the export
          job's PR must be merged first).
        '';
      }
    ]
    ++ map (u: {
      assertion = config.users.users ? ${u};
      message = ''
        clusterNode: user ${u} owns cluster keys on ${name} but does not
        exist here (etcd/kubernetes create it).
      '';
    }) owners;

    sops.secrets = lib.listToAttrs (leafSecrets ++ saSecrets);
    sops.templates = lib.listToAttrs bundles;

    environment.etc."kubernetes/admin.kubeconfig" = lib.mkIf (lib.elem "admin" leaves) {
      source = adminKubeconfig;
      mode = "0600";
      user = "root";
      group = "root";
    };
  };
}
