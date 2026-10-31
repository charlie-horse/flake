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
  final = cfg.etcd.phase == "final";
  # "trust" phase: the legacy member cert (tls/etcd/peer/etcd.pem, issuer
  # "ETCD CA 1", EKU server+client, SAN <n>/localhost/127.0.0.1) was both
  # server and peer cert; it is copied out of /etc/nixos into secretsDir
  # (docs/cluster-handoff.md step 1), so no Nix path is involved.
  legacy = cfg.leaf "legacy-etcd-peer";
  server = if final then cfg.leaf "etcd-server" else legacy;
  peer = if final then cfg.leaf "etcd-peer" else legacy;
  # New + legacy CA (cluster-pki --trust etcd <legacy CA>) until
  # `cluster-pki --rotate-ca etcd --phase finish`.
  ca = cfg.secret "etcd-ca.pem";
in
{
  config = lib.mkIf (cfg.enable && lib.elem "etcd" cfg.activeRoles) {
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

      # Peer side (etcd <-> etcd): etcd-peer-<node> leaf, mutual TLS once
      # every member is "final" (off in "trust", as in the legacy config).
      peerClientCertAuth = final;
      peerTrustedCaFile = ca;
      peerCertFile = peer.cert;
      peerKeyFile = peer.key;
    };
  };
}
