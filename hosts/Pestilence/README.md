# Pestilence (archived)

Archived on 2026-11-12. Pestilence is not built or checked: it is not in
`flake.nixosConfigurations` (`parts/hosts.nix`) and has no installer ISO
(`parts/packages.nix`). The files here are kept as they were.

It was last evaluated against nixpkgs-unstable
`4633a7c72337ea8fd23a4f2ba3972865e3ec685d` (the `nixpkgs-unstable` input in
`flake.lock` at the time of archiving).

To restore it, re-add the mkHost line in `parts/hosts.nix`:

```nix
(lib.system.x86_64-linux.mkHost ../hosts/Pestilence)
```

(and, if wanted, its ISO in `parts/packages.nix`), then fix it for the
current nixpkgs-unstable. Starting points seen at archiving (not a full
list): `hardware.opengl` became `hardware.graphics`, `vaapiVdpau` became
`libva-vdpau-driver`, and transmission 3 is gone, so `servarr.nix` needs
`package = pkgs.transmission_4` (back up `/mutable/transmission` first;
3 -> 4 can lose data, see the NixOS 24.11 release notes).

`servarr.nix` still holds a plaintext `rpc-password`; CI's format job
excludes that file and the secrets guard flags any edit of that line. Move
the secret out of git before restoring the host.
