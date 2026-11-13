# clusterNode.certSource = "sops": the node's cluster certs and keys come
# from sops-nix instead of `cluster-pki deploy` (docs/pki-migration-plan.md,
# phase 2, P3). With "files" (the default) this module defines nothing.
#
# Layout under clusterNode.secretsDir = /run/secrets/pki (sops-nix's ramfs;
# a new generation on every activation, before any unit starts):
#   <component>-<node>.pem / -key.pem  sops.secrets."pki/<file>" from
#       secrets/pki/<node>.yaml (keys = these file names; certs plaintext,
#       keys encrypted; written by the in-cluster export job). Which
#       components a node gets comes from the leaf list the Certificates
#       are made from (k8s/components/infra/cluster-pki/leaves.nix, by the
#       node's roles), asserted equal to cluster-pki's own SPECS table, so
#       the file set is exactly what `cluster-pki deploy` installs today,
#       including the unused addon-manager-* and flannel-* leaves.
#       The values have no trailing newline (the export job writes `|-`),
#       so sops-nix's files don't end in one either; every reader here
#       (Go: etcd, kube-*) parses PEM without it, and nothing in this
#       module concatenates them.
#   sa.key / sa.pub  (controlPlane) from the host's own secrets/<node>.yaml.
#   ca.pem etcd-ca.pem front-proxy-ca.pem  the public bundles from
#       cluster/pki/{k8s,etcd,front-proxy}-ca.pem in git, as sops templates
#       (0644 root, rendered into the same generation as the secrets, so
#       they exist whenever the leaves do; symlinks into /run/secrets/
#       rendered/pki/).
# Owners and modes are those of cluster-pki's node_files (= the deploy
# script's install lines). restartUnits restarts what reads a changed file;
# units that are not enabled on this host (rollout.stage) are left out.
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

  # The node's leaves (components), by its roles in the definition (not the
  # rollout stage): the list the cert-manager Certificates, and so the
  # export job's secrets/pki/<node>.yaml, are made from.
  leaves = map (l: l.component) (
    lib.filter (l: l.node == name) (
      import ../../k8s/components/infra/cluster-pki/leaves.nix { inherit lib cluster; }
    )
  );

  # The same from cluster-pki's own table (SPECS in cluster-pki.sh, lines
  # "component|ca|profile|CN|O|sans|role"), which `cluster-pki deploy`
  # installs today: asserted equal below, so the two cannot drift apart
  # unnoticed while hosts still switch between "files" and "sops".
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

  # Units that read each component's leaf (none: admin is for kubectl,
  # addon-manager and flannel have no unit here).
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
      mode,
      restart,
      sopsFile ? pkiSopsFile,
    }:
    lib.nameValuePair "pki/${file}" {
      inherit sopsFile owner mode;
      group = owner;
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
        mode = "0644";
        inherit restart;
      })
      (secret {
        file = "${c}-${name}-key.pem";
        owner = keyOwner c;
        mode = "0600";
        inherit restart;
      })
    ]
  ) leaves;

  # Static, from the host's default sops file (moved there by hand once).
  saSecrets = lib.optionals hasCP [
    (secret {
      file = "sa.pub";
      owner = "root";
      mode = "0644";
      restart = [ "kube-apiserver" ];
      sopsFile = config.sops.defaultSopsFile;
    })
    (secret {
      file = "sa.key";
      owner = "kubernetes";
      mode = "0600";
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
      {
        assertion = cfg.secretsDir == "/run/secrets/pki";
        message = ''
          clusterNode.certSource = "sops" reads the certs from
          /run/secrets/pki (got secretsDir = ${cfg.secretsDir}).
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

    sops.secrets = lib.listToAttrs (leafSecrets ++ saSecrets);
    sops.templates = lib.listToAttrs bundles;
  };
}
