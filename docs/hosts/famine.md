# Famine

The desktop workstation (`hosts/Famine/`, built with `mkHost`).

## Deploy

On Famine, from its checkout: `sudo nixos-rebuild switch --flake .#Famine`.
Do not switch to a sops generation before the
[enrolment](#enrolling-famine-in-sops) is done.

## YubiKey

To turn on `custom.yubikey.enable` (pam_u2f for login and sudo), make the
mappings at Famine with the YubiKey 5 plugged in (`modules/system/yubikey.nix`
has the format), add them to `secrets/famine.yaml` as `pam-yubikeys`, then set it to true (step 3
below). PAM behaviour: [auth.md](../auth.md) (`custom.auth.desktopU2f`).

## Enrolling Famine in sops

Famine can decrypt `secrets/common.yaml` and `secrets/famine.yaml` only once
it is a recipient of both in `.sops.yaml`.

**Do not switch Famine to a sops generation before step 4.**
`users.mutableUsers = false` and root is locked. If Famine can't decrypt
`common.yaml` and `famine.yaml`, it boots with no usable password for admin
or charlie. Recovery means picking an older generation in the boot menu.

To read charlie's password, run this anywhere the YubiKey is plugged in. It
needs the PIV PIN and a touch:
`sops -d --extract '["charlie-password"]' secrets/famine.yaml`

### Procedure

1. **Host key.** On Famine, while it's still on a pre-sops generation, run
   `sudo ssh-keygen -A`. This creates `/etc/ssh/ssh_host_ed25519_key` without
   enabling sshd. The `sopsHostKey` activation script creates it only during
   the first sops switch, which is too late.
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
   installed; on c4130 it all runs as root, see
   [secrets.md](../secrets.md) for the exact commands):
   `sops updatekeys -y secrets/common.yaml secrets/famine.yaml`
3. **YubiKey secrets (optional, needs the YubiKey 5 at Famine).**
   - `pam-yubikeys`: run `pamu2fcfg -o pam://sortofasian -i pam://sortofasian`.
   - ssh and git signing need no secret: they use the `ssh:admin` key from
     the agent (`ssh-keygen -K` + `ssh-add` where the YubiKey is plugged in).
   - Add the value with `sops secrets/famine.yaml`, then set
     `custom.yubikey.enable = true` in `hosts/Famine/default.nix`. The
     comments in `modules/system/yubikey.nix` give the exact formats
     ([YubiKey](#yubikey)).
4. **Check that decryption works (automatic, optional by hand).** The
   pre-switch check `sopsDecrypt` (`modules/system/sops.nix`) decrypts
   `common.yaml` and `famine.yaml` with the host key before anything is
   activated, and aborts (bootloader and system untouched) if either fails
   or the host key is missing. CI fails if a file's recipients don't match
   `.sops.yaml` (step 2 forgotten `updatekeys`). Optional check before
   merging, on Famine from the branch checkout:
   ```sh
   for f in secrets/common.yaml secrets/famine.yaml; do
     sudo SOPS_AGE_KEY_CMD="$(nix build --no-link --print-out-paths nixpkgs#ssh-to-age)/bin/ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key" \
       "$(nix build --no-link --print-out-paths nixpkgs#sops)/bin/sops" -d "$f" >/dev/null && echo "$f OK"
   done
   ```
   Both should print OK. Use `SOPS_AGE_KEY_CMD` + `ssh-to-age`;
   `SOPS_AGE_SSH_PRIVATE_KEY_FILE` doesn't work with sops 3.13.
5. **Deploy.** Open a PR, wait for CI, and merge. Then on Famine:
   `sudo nixos-rebuild switch --flake .#Famine`. Log in as charlie with the
   password from `charlie-password`; use `admin` for sudo (charlie is not in
   wheel).
