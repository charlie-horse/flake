# CoreDNS: cluster DNS at cluster.dnsServiceIP (the kubelets' clusterDNS,
# modules/cluster/node.nix) for cluster.clusterDomain. The Service is named
# kube-dns and the pods labelled k8s-app=kube-dns, as kubeadm clusters do,
# so tools that look for either find it.
#
# Upstream resolution: `forward . /etc/resolv.conf`, the node's resolver
# (CoreDNS pods use dnsPolicy Default). On every node that is Tailscale's
# 100.100.100.100, so MagicDNS names (<node>.leaffish-monster.ts.net)
# resolve from pods too; flannel's --ip-masq SNATs the queries to the
# node. The fd7a:...::53 entry is unreachable from IPv4-only pods and is
# simply marked unhealthy by `forward`.
{
  pkgs,
  catenix,
  charts,
  cluster,
  kubeVersion,
  ...
}:
let
  labels."k8s-app" = "kube-dns";
in
{
  imports = [
    (catenix.importChart {
      inherit pkgs kubeVersion;
      chart = charts.coredns;
      release = {
        name = "coredns";
        namespace = "kube-system";
      };
      values = {
        fullnameOverride = "coredns";
        k8sAppLabelOverride = "kube-dns";
        replicaCount = 2;
        # Its own ServiceAccount (the chart default binds the ClusterRole
        # to kube-system's `default`).
        serviceAccount.create = true;
        service = {
          name = "kube-dns";
          clusterIP = cluster.dnsServiceIP;
        };
        # Only the two DNS replicas need to spread over the nodes.
        affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = [
          {
            weight = 100;
            podAffinityTerm = {
              topologyKey = "kubernetes.io/hostname";
              labelSelector.matchLabels = labels;
            };
          }
        ];
        priorityClassName = "system-cluster-critical";
        servers = [
          {
            zones = [
              {
                zone = ".";
                use_tcp = true;
              }
            ];
            port = 53;
            plugins = [
              { name = "errors"; }
              {
                name = "health";
                configBlock = "lameduck 10s";
              }
              { name = "ready"; }
              {
                name = "kubernetes";
                parameters = "${cluster.clusterDomain} in-addr.arpa ip6.arpa";
                configBlock = ''
                  pods insecure
                  fallthrough in-addr.arpa ip6.arpa
                  ttl 30'';
              }
              {
                name = "prometheus";
                parameters = "0.0.0.0:9153";
              }
              {
                name = "forward";
                parameters = ". /etc/resolv.conf";
              }
              {
                name = "cache";
                parameters = 30;
              }
              { name = "loop"; }
              { name = "reload"; }
              { name = "loadbalance"; }
            ];
          }
        ];
      };
    })
  ];

  validation.strict = true;
}
