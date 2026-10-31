# etcd member on nodes with the "etcd" role.
#
# Member names and peer URLs are EXACTLY what the running cluster has
# (r440, c4130, m2mini; https://<name>:2380): no membership change. <name>
# resolves to the node's tailnet IP via MagicDNS. initialCluster/-State only
# matter when a data dir is created; existing members ignore them.
{ config, lib, cluster, ... }:
let
  cfg = config.clusterNode;
  name = cfg.name;
  # Today's order (the old k8s.nix files); cosmetic, kept for stable env.
  memberOrder = [ "r440" "c4130" "m2mini" ];
  etcdNodes = lib.filter (n: lib.elem "etcd" cluster.nodes.${n}.roles)
    (lib.filter (n: cluster.nodes ? ${n}) memberOrder
      ++ lib.subtractLists memberOrder (lib.attrNames cluster.nodes));
  server = cfg.leaf "etcd-server";
  peer = cfg.leaf "etcd-peer";
  ca = cfg.secret "etcd-ca.pem";
in
{
  config = lib.mkIf (cfg.enable && lib.elem "etcd" cfg.node.roles) {
    services.etcd = {
      enable = true;
      inherit name;
      initialClusterState = "new";
      initialCluster = map (n: "${n}=https://${n}:2380") etcdNodes;
      initialAdvertisePeerUrls = [ "https://${name}:2380" ];
      advertiseClientUrls = [ "https://${name}:2379" ];
      listenClientUrls = [ "https://0.0.0.0:2379" ];
      listenPeerUrls = [ "https://0.0.0.0:2380" ];

      # Client side (apiserver -> etcd): etcd-server-<node> leaf.
      clientCertAuth = true;
      trustedCaFile = ca;
      certFile = server.cert;
      keyFile = server.key;

      # Peer side (etcd <-> etcd): etcd-peer-<node> leaf, mutual TLS.
      peerClientCertAuth = true;
      peerTrustedCaFile = ca;
      peerCertFile = peer.cert;
      peerKeyFile = peer.key;
    };
  };
}
