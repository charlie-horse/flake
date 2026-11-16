# Keep /etc/containers as it was under cri-o (which enabled
# virtualisation.containers implicitly), for rootless podman.
# docs/hosts/r440.md#containers
{ ... }:
{
  virtualisation.containers.enable = true;
}
