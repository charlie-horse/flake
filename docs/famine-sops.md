# Enrolling Famine in sops

Famine was offline when the repo moved from agenix to sops-nix (2026-11-13),
so it is **not yet a recipient** of anything. `secrets/famine.yaml` exists,
but it's encrypted only to the admin keys (YubiKey PIV slot 82 and the offline
backup key), so Famine can't decrypt it. `secrets/common.yaml` (the admin
password) doesn't include Famine either.

**Do not switch Famine to a sops-era generation before step 4.**
`users.mutableUsers = false` and root is locked. If Famine can't decrypt
`common.yaml` and `famine.yaml`, it boots with no usable password for admin
or charlie. Recovery means picking an older generation in the boot menu.

## What `secrets/famine.yaml` already holds

| Key | Value |
| --- | --- |
| `nix-cache-netrc` | Famine's binary-cache login (the existing `famine` htpasswd user on r440) |
| `charlie-password` | charlie's new Famine login password, random. Deployed with `neededForUsers`; Famine derives its yescrypt hash at activation (`custom.sopsPasswords`, `modules/system/sops.nix`) |
| `charlie-password-hash` | old yescrypt hash of the above, no longer used (nothing declares it; drop it at the next edit) |

To read charlie's password, run this anywhere the YubiKey is plugged in. It
needs the PIV PIN and a touch:
`sops -d --extract '["charlie-password"]' secrets/famine.yaml`

## Procedure

1. **Host key.** On Famine, while it's still on its old generation, run
   `sudo ssh-keygen -A`. This creates `/etc/ssh/ssh_host_ed25519_key` without
   enabling sshd. The `sopsHostKey` activation script would also create it,
   but only during the first sops switch, which is too late.
   Then print the recipient:
   `nix run nixpkgs#ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub`
2. **Recipients.** On a branch, edit `.sops.yaml`:
   - add `- &famine <that age1… key>` to `keys:`;
   - add `- *famine` to the `secrets/common.yaml` rule;
   - change the `secrets/famine.yaml` rule to
     `[*admin_yubikey, *admin_backup, *famine]`;
   - delete the "Famine: not a recipient yet" comment.

   Then re-wrap both files. This needs the backup key or the YubiKey, used
   ad hoc on any machine it's plugged into: `nix shell nixpkgs#sops
   nixpkgs#age-plugin-yubikey` plus a temporary pcscd (no host has them
   installed; on c4130 it all runs as root, see `docs/cluster.md`, "Secrets
   (all of them)", for the exact commands):
   `sops updatekeys -y secrets/common.yaml secrets/famine.yaml`
3. **YubiKey secrets (optional, needs the YubiKey 5 at Famine).**
   - `pam-yubikeys`: run `pamu2fcfg -o pam://sortofasian -i pam://sortofasian`.
   - `ssh-yubikey-5`: if the key is resident, run `ssh-keygen -K`; otherwise
     make a new `ssh-keygen -t ed25519-sk -O resident` key and update GitHub.
   - Add the two values with `sops secrets/famine.yaml`, then set
     `custom.yubikey.enable = true` in `hosts/Famine/default.nix`. The
     comments in `modules/system/yubikey.nix` give the exact formats.
4. **Check that decryption works (automatic, optional by hand).** The
   switch now refuses on its own: the pre-switch check `sopsDecrypt`
   (`modules/system/sops.nix`) decrypts `common.yaml` and `famine.yaml` with
   the host key before anything is activated, and aborts (bootloader and
   system untouched) if either fails or the host key is missing. CI also
   fails if a file's recipients don't match `.sops.yaml` (step 2 forgotten
   `updatekeys`). As an optional sanity check before merging, on Famine from
   the branch checkout:
   ```sh
   for f in secrets/common.yaml secrets/famine.yaml; do
     sudo SOPS_AGE_KEY_CMD="$(nix build --no-link --print-out-paths nixpkgs#ssh-to-age)/bin/ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key" \
       "$(nix build --no-link --print-out-paths nixpkgs#sops)/bin/sops" -d "$f" >/dev/null && echo "$f OK"
   done
   ```
   Both should print OK. (`SOPS_AGE_SSH_PRIVATE_KEY_FILE` didn't work with
   sops 3.13 here; `SOPS_AGE_KEY_CMD` + `ssh-to-age` does.)
5. **Deploy.** Open a PR, wait for CI, and merge. Then on Famine:
   `sudo nixos-rebuild switch --flake .#Famine`. Log in as charlie with the
   password from `charlie-password`; use `admin` for sudo.
6. **Clean up.** Once Famine's netrc works from sops, the netrc is no longer
   needed in `r440:/root/nix-cache-setup/`. Shred that directory if every
   other host has switched too (`docs/cluster.md`, "Secrets (all of them)").

## Decisions

- **charlie's Famine password** (decided 2026-11: kept). charlie always
  has a password on the desktop, from `charlie-password`
  (`modules/system/user.nix`), for the greeter and hyprlock.
- **sudo on Famine.** charlie is no longer in wheel, so sudo needs `admin`.
