# Keep /etc/containers/{containers.conf,storage.conf,policy.json,
# registries.conf} exactly as they were under cri-o, which enabled
# virtualisation.containers implicitly: rootless podman (charlie's, --root
# under ~/flint-swebench and ~/.local/share/containers) reads them, and the
# cri-o -> containerd swap must not change what it sees. charlie exists
# while custom.server.legacyCharlie.enable is on (his /etc/subuid range
# 100000:65536 from isNormalUser, autoSubUidGidRange). admin gets its own
# range, NOT charlie's (that stays reserved in /var/lib/nixos/
# auto-subuid-map after charlie is removed), so charlie's rootless
# container storage is not usable by admin as is (docs/cluster.md,
# "Removing charlie from the servers").
{ ... }:
{
  virtualisation.containers.enable = true;
}
