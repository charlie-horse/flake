# Must match what pkgs/cluster-pki/cluster-pki.sh issues (SPECS, node_sans,
# apiserver_sans, cfssl profiles). modules/cluster/pki-sops.nix checks SPECS.
{ lib, cluster }:
let
  columns = [
    "component"
    "ca"
    "profile"
    "cn"
    "o"
    "sans"
    "role"
  ];
  specs =
    map (line: lib.listToAttrs (lib.zipListsWith lib.nameValuePair columns (lib.splitString "|" line)))
      [
        "etcd-peer|etcd|peer|@NODE@||node|etcd"
        "etcd-server|etcd|peer|@NODE@||node|etcd"
        "etcd-client-apiserver|etcd|client|kube-apiserver-etcd-client|||controlPlane"
        "apiserver|k8s|server|kube-apiserver||apiserver|controlPlane"
        "apiserver-kubelet-client|k8s|client|system:kube-apiserver|||controlPlane"
        "front-proxy-client|front-proxy|client|front-proxy-client|||controlPlane"
        "controller-manager|k8s|client|system:kube-controller-manager|||controlPlane"
        "scheduler|k8s|client|system:kube-scheduler|||controlPlane"
        "admin|k8s|client|cluster-admin|system:masters||controlPlane"
        "addon-manager|k8s|client|system:kube-addon-manager|||controlPlane"
        "kubelet|k8s|peer|system:node:@NODE@|system:nodes|node|worker"
        "kube-proxy|k8s|client|system:kube-proxy|system:node-proxier||worker"
        "flannel|k8s|client|flannel-client|||worker"
      ];

  usages = {
    server = [
      "digital signature"
      "key encipherment"
      "server auth"
    ];
    client = [
      "digital signature"
      "key encipherment"
      "client auth"
    ];
    peer = [
      "digital signature"
      "key encipherment"
      "server auth"
      "client auth"
    ];
  };

  domain = cluster.domain or "";

  nodeSANs =
    n:
    let
      x = cluster.nodes.${n};
    in
    [ n ]
    ++ lib.optional (domain != "") "${n}.${domain}"
    ++ lib.optional (x ? tailnetIP) x.tailnetIP
    ++ lib.optional (x ? lanIP) x.lanIP
    ++ [
      "127.0.0.1"
      "localhost"
    ]
    ++ (x.extraSANs or [ ]);

  apiserverSANs =
    n:
    nodeSANs n
    ++ lib.optional (cluster ? vip) cluster.vip
    ++ lib.optional (cluster ? kubernetesServiceIP) cluster.kubernetesServiceIP
    ++ [
      "kubernetes"
      "kubernetes.default"
      "kubernetes.default.svc"
      "kubernetes.default.svc.${cluster.clusterDomain or "cluster.local"}"
    ]
    ++ (cluster.apiserverExtraSANs or [ ]);

  # As cfssl splits -hostname: anything that parses as an IP is an IP SAN.
  isIP = s: builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+" s != null || lib.hasInfix ":" s;
  normalise = l: lib.sort lib.lessThan (lib.unique l);

  leaf =
    n:
    {
      component,
      ca,
      profile,
      cn,
      o,
      sans,
    }:
    let
      all =
        {
          "" = [ ];
          node = nodeSANs n;
          apiserver = apiserverSANs n;
        }
        .${sans};
    in
    {
      name = "${component}-${n}";
      node = n;
      inherit component ca profile;
      commonName = builtins.replaceStrings [ "@NODE@" ] [ n ] cn;
      organizations = lib.optional (o != "") o;
      dnsNames = normalise (builtins.filter (s: !isIP s) all);
      ipAddresses = normalise (builtins.filter isIP all);
      usages = usages.${profile};
    };

  nodeLeaves =
    n:
    map (spec: leaf n (removeAttrs spec [ "role" ])) (
      lib.filter (spec: lib.elem spec.role (cluster.nodes.${n}.roles or [ ])) specs
    );
in
assert lib.assertMsg (lib.allUnique (
  map (l: l.name) (lib.concatMap nodeLeaves (lib.attrNames cluster.nodes))
)) "cluster-pki leaves: two leaves share a file name";
lib.concatMap nodeLeaves (lib.attrNames cluster.nodes)
