# Keep /etc/containers/{containers.conf,storage.conf,policy.json,
# registries.conf} exactly as they were under cri-o, which enabled
# virtualisation.containers implicitly: rootless podman (formerly charlie's,
# --root under ~/flint-swebench and ~/.local/share/containers) reads them,
# and the cri-o -> containerd swap must not change what it sees.
# Since charlie's removal (2026-11) the only login is admin. Its /etc/subuid
# range comes from isNormalUser (autoSubUidGidRange) and is NOT charlie's
# old 100000:65536 (that stays reserved in /var/lib/nixos/auto-subuid-map),
# so charlie's rootless container storage is not usable by admin as is
# (docs/cluster.md, "Removing charlie from the servers").
{ ... }:
{
  virtualisation.containers.enable = true;
}
