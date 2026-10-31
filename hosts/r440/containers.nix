# Keep /etc/containers/{containers.conf,storage.conf,policy.json,
# registries.conf} exactly as they were under cri-o, which enabled
# virtualisation.containers implicitly. User charlie runs ROOTLESS podman
# (its own podman, --root under ~/flint-swebench and ~/.local/share/
# containers, ~/.config/containers/{policy,registries}.*); the cri-o ->
# containerd swap must not change what it sees. /etc/subuid
# (charlie:100000:65536) comes from isNormalUser (autoSubUidGidRange) and
# does not depend on this.
{ ... }:
{
  virtualisation.containers.enable = true;
}
