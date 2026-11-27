# VPS hosts (nether, phoenix)

nether and phoenix are small virtual servers (VPS) at Bluehost, outside the
cluster (`hosts/nether/`, `hosts/phoenix/`). Each is installed once with
**nixos-anywhere**, a tool that logs in to a running Linux over SSH as
root, boots a NixOS installer in memory (kexec), partitions the disk with
**disko** (`modules/server/vps-disk.nix`) and installs this flake's host.
After the install, Tailscale SSH is the only way in
([CLAUDE.md](../../CLAUDE.md#access)); later changes follow
[cluster.md](../cluster.md#changing-a-host).

## Installing a VPS

The install erases the disk. Run it from an x86_64 Linux machine with Nix
and this repo checked out (it builds the system there), that can reach the
VPS's public address on port 22 as root. `<host>` is `nether` or
`phoenix`.

1. **Files for the new system.** In a folder on tmpfs (RAM, never on disk
   or in git), make the tree nixos-anywhere copies onto the VPS:
   ```sh
   X=$(mktemp -d /dev/shm/vps.XXXXXX)
   install -d -m 0755 "$X/etc/ssh"
   install -d -m 0700 "$X/var/lib/tailscale"
   ssh-keygen -q -t ed25519 -N "" -C "" -f "$X/etc/ssh/ssh_host_ed25519_key"
   ```
   The key is the host's SSH host key and its sops identity.
2. **Enroll the host in sops.** Print its recipient:
   `nix run nixpkgs#ssh-to-age < "$X/etc/ssh/ssh_host_ed25519_key.pub"`.
   On a branch, add `- &<host> <that age1… key>` to `keys:` in
   `.sops.yaml` and `- *<host>` to the `secrets/common.yaml` rule. Re-wrap
   the file ([secrets.md](../secrets.md)):
   `sops updatekeys -y secrets/common.yaml`. PR, CI, merge. Without this
   step the install stops at the pre-switch check
   ([auth.md](../auth.md#sops-nix-on-the-hosts)).
3. **Tailscale auth key.** Make one as in
   [cluster.md](../cluster.md#tailscale) and paste it into the file
   (end with Ctrl-D):
   `(umask 077; cat > "$X/var/lib/tailscale/authkey")`
4. **Install**, from the merged `main`:
   ```sh
   nix run github:nix-community/nixos-anywhere -- \
     --flake .#<host> --extra-files "$X" --target-host root@<public address>
   ```
   The VPS reboots into NixOS.
5. **Check and clean up.** `tailscale status` lists `<host>`. Then
   `ssh admin@<host>`, run `sudo rm /var/lib/tailscale/authkey`, and delete
   the local folder: `rm -rf "$X"`.
