# The cluster's bootstrap leaves, as pkgs/cluster-pki/cluster-pki.sh issues
# them today (its SPECS table, node_sans, apiserver_sans and cfssl
# profiles), computed from cluster/definition.nix. Keep the two in step:
# the leaves cert-manager issues must match the files cluster-pki makes
# (docs/pki-migration-plan.md, phase 2).
#
# `import ./leaves.nix { inherit lib cluster; }` is a list of
#   {
#     name          file stem, e.g. "apiserver-r440" (= Certificate and
#                   Secret name, and <name>.pem / <name>-key.pem on the host)
#     node          "r440"
#     component     "apiserver"
#     ca            "k8s" | "etcd" | "front-proxy"
#     profile       "server" | "client" | "peer"
#     commonName    e.g. "kube-apiserver", "system:node:r440"
#     organizations [ ] or [ "system:masters" ] etc.
#     dnsNames      sorted, unique
#     ipAddresses   sorted, unique
#     usages        cert-manager key usages of the profile
#   }
# for every node and every leaf its roles call for (flannel-* and
# addon-manager-* included: cluster-pki still makes them).
{ lib, cluster }:
let
  # component, ca, profile, CN (@NODE@ = node name), O, SANs (none | node |
  # apiserver), role: SPECS in cluster-pki.sh, line for line.
  specs = [
    [
      "etcd-peer"
      "etcd"
      "peer"
      "@NODE@"
      ""
      "node"
      "etcd"
    ]
    [
      "etcd-server"
      "etcd"
      "peer"
      "@NODE@"
      ""
      "node"
      "etcd"
    ]
    [
      "etcd-client-apiserver"
      "etcd"
      "client"
      "kube-apiserver-etcd-client"
      ""
      ""
      "controlPlane"
    ]
    [
      "apiserver"
      "k8s"
      "server"
      "kube-apiserver"
      ""
      "apiserver"
      "controlPlane"
    ]
    [
      "apiserver-kubelet-client"
      "k8s"
      "client"
      "system:kube-apiserver"
      ""
      ""
      "controlPlane"
    ]
    [
      "front-proxy-client"
      "front-proxy"
      "client"
      "front-proxy-client"
      ""
      ""
      "controlPlane"
    ]
    [
      "controller-manager"
      "k8s"
      "client"
      "system:kube-controller-manager"
      ""
      ""
      "controlPlane"
    ]
    [
      "scheduler"
      "k8s"
      "client"
      "system:kube-scheduler"
      ""
      ""
      "controlPlane"
    ]
    [
      "admin"
      "k8s"
      "client"
      "cluster-admin"
      "system:masters"
      ""
      "controlPlane"
    ]
    [
      "addon-manager"
      "k8s"
      "client"
      "system:kube-addon-manager"
      ""
      ""
      "controlPlane"
    ]
    [
      "kubelet"
      "k8s"
      "peer"
      "system:node:@NODE@"
      "system:nodes"
      "node"
      "worker"
    ]
    [
      "kube-proxy"
      "k8s"
      "client"
      "system:kube-proxy"
      "system:node-proxier"
      ""
      "worker"
    ]
    [
      "flannel"
      "k8s"
      "client"
      "flannel-client"
      ""
      ""
      "worker"
    ]
  ];

  # cfssl profiles (cfssl_config): "signing" is cfssl's name for
  # digitalSignature.
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

  # node_sans: short name, FQDN, tailnet IP, LAN IP, loopback, extras.
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

  # apiserver_sans: node SANs, the VIP, the `kubernetes` Service IP and
  # names, apiserverExtraSANs.
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

  # cfssl puts a -hostname entry that parses as an IP into the IP SANs and
  # the rest into the DNS SANs (cluster-pki sorts and dedups the list).
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
    lib.concatMap (
      spec:
      let
        at = lib.elemAt spec;
        role = at 6;
      in
      lib.optional (lib.elem role (cluster.nodes.${n}.roles or [ ])) (
        leaf n {
          component = at 0;
          ca = at 1;
          profile = at 2;
          cn = at 3;
          o = at 4;
          sans = at 5;
        }
      )
    ) specs;
in
assert lib.assertMsg (lib.allUnique (
  map (l: l.name) (lib.concatMap nodeLeaves (lib.attrNames cluster.nodes))
)) "cluster-pki leaves: two leaves share a file name";
lib.concatMap nodeLeaves (lib.attrNames cluster.nodes)
