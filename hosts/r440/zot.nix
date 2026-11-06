# Data directory for the in-cluster Zot registry (k8s/components/zot.nix),
# a hostPath pinned to this node. uid/gid 10500 is the pod's runAsUser.
{ ... }:
{
  systemd.tmpfiles.rules = [ "d /var/lib/zot 0750 10500 10500 -" ];
}
