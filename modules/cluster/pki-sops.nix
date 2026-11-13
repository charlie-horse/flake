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
  sops = cfg.certSource == "sops";

  # By roles, not rollout stage: the set the export job writes to secrets/pki/<node>.yaml.
  leaves = map (l: l.component) (
    lib.filter (l: l.node == name) (
      import ../../k8s/components/infra/cluster-pki/leaves.nix { inherit lib cluster; }
    )
  );

  # What `cluster-pki deploy` installs; must equal `leaves` while hosts mix "files" and "sops".
  specLeaves =
    let
      script = builtins.readFile ../../pkgs/cluster-pki/cluster-pki.sh;
      parts = lib.splitString "\nSPECS='" script;
      body = lib.head (lib.splitString "'" (lib.elemAt parts 1));
      fields = map (lib.splitString "|") (lib.filter (l: l != "") (lib.splitString "\n" body));
    in
    if lib.length parts != 2 || lib.any (f: lib.length f != 7) fields then
      throw "modules/cluster/pki-sops.nix: cannot parse SPECS in pkgs/cluster-pki/cluster-pki.sh"
    else
      map lib.head (lib.filter (f: lib.elem (lib.elemAt f 6) cfg.node.roles) fields);

  hasEtcd = lib.elem "etcd" cfg.node.roles;
  hasCP = lib.elem "controlPlane" cfg.node.roles;

  # node_files in cluster-pki.sh: key owners.
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
      # Keys 0600, certs and sa.pub 0644 (cluster-pki node_files).
      mode = if lib.hasSuffix "-key.pem" file || file == "sa.key" then "0600" else "0644";
      key = file;
      path = "${cfg.secretsDir}/${file}";
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

  # Static, from the host's default sops file (moved there by hand once).
  saSecrets = lib.optionals hasCP [
    (secret {
      file = "sa.pub";
      owner = "root";
      restart = [ "kube-apiserver" ];
      sopsFile = config.sops.defaultSopsFile;
    })
    (secret {
      file = "sa.key";
      owner = "kubernetes";
      restart = [
        "kube-apiserver"
        "kube-controller-manager"
      ];
      sopsFile = config.sops.defaultSopsFile;
    })
  ];

  # Public trust bundles (intermediate only, the anchor rule) from git.
  bundle =
    file: src: restart:
    lib.nameValuePair "pki/${file}" {
      file = src;
      path = "${cfg.secretsDir}/${file}";
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
in
{
  config = lib.mkIf (cfg.enable && sops) {
    assertions = [
      {
        assertion = pkiSopsExists;
        message = ''
          clusterNode.certSource = "sops" on ${name}, but secrets/pki/${name}.yaml
          does not exist (the export job's PR must be merged first).
        '';
      }
      {
        assertion = lib.sort lib.lessThan leaves == lib.sort lib.lessThan specLeaves;
        message = ''
          clusterNode.certSource = "sops" on ${name}: the leaves in
          k8s/components/infra/cluster-pki/leaves.nix (${toString leaves})
          differ from SPECS in pkgs/cluster-pki/cluster-pki.sh
          (${toString specLeaves}); keep the two in step.
        '';
      }
      {
        assertion = cfg.etcd.phase == "final";
        message = ''
          clusterNode.certSource = "sops" needs etcd.phase "final" on ${name}:
          the legacy-etcd-* leaves of "trust" are not in secrets/pki/.
        '';
      }
    ]
    ++ map (u: {
      assertion = config.users.users ? ${u};
      message = ''
        clusterNode.certSource = "sops": user ${u} owns cluster keys on
        ${name} but does not exist here (etcd/kubernetes create it).
      '';
    }) owners;

    clusterNode.secretsDir = "/run/secrets/pki";

    sops.secrets = lib.listToAttrs (leafSecrets ++ saSecrets);
    sops.templates = lib.listToAttrs bundles;
  };
}
