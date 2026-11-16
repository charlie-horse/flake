# Pestilence (archived)

Former x86_64 home server (`hosts/Pestilence/`: ZFS pool `mutable`, haproxy
with TLS, Minecraft servers behind Velocity, the *arr stack with
Transmission, Vaultwarden, shadowsocks; Grafana configured but disabled). Archived on 2026-11-12: it
is not in `flake.nixosConfigurations` (`parts/hosts.nix`) and has no
installer ISO (`parts/packages.nix`), so it is neither built nor checked
([ci.md](../ci.md)). The files are kept as they were.

It was last evaluated against nixpkgs-unstable
`4633a7c72337ea8fd23a4f2ba3972865e3ec685d` (the `nixpkgs-unstable` input in
`flake.lock` at the time of archiving).

## Restoring it

1. Re-add the mkHost line in `parts/hosts.nix`:
   ```nix
   (lib.system.x86_64-linux.mkHost ../hosts/Pestilence)
   ```
   and, if wanted, its ISO in `parts/packages.nix`.
2. Move the plaintext Transmission `rpc-password` in `servarr.nix` out of
   git (rotate it, put it in sops; [secrets.md](../secrets.md)). CI's format
   job excludes `servarr.nix`, and the secrets guard flags any edit of that
   line.
3. Remake the agenix-only secrets, which are lost (`key-pestilence`,
   `vpn-privkey`, `vpn-password`, `acme-cloudflare`;
   [secrets.md](../secrets.md)).
4. Fix it for the current nixpkgs-unstable. Starting points seen at
   archiving (not a full list):
   - `hardware.opengl` became `hardware.graphics`;
   - `vaapiVdpau` became `libva-vdpau-driver`;
   - transmission 3 is gone, so `servarr.nix` needs
     `package = pkgs.transmission_4`. Back up `/mutable/transmission`
     first: 3 → 4 can lose data (NixOS 24.11 release notes).
