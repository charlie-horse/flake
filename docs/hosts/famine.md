# Famine

Famine is the desktop workstation (`hosts/Famine/`). sops is the tool that
keeps secrets encrypted in git (`secrets/`); a host can read a file only if
it is one of the file's recipients in `.sops.yaml`.

## Deploy

On Famine, from its checkout: `sudo nixos-rebuild switch --flake .#Famine`.

**Never switch Famine to a sops generation before step 4 of the
[enrolment](#enrolling-famine-in-sops).** Users are not mutable and root is
locked, so a Famine that can't decrypt `secrets/common.yaml` and
`secrets/famine.yaml` boots with no usable password for admin or charlie.
To recover, pick an older generation in the boot menu.

## YubiKey

`custom.yubikey.enable` turns on pam_u2f (YubiKey touch) for login and
sudo. To enable it:

1. At Famine, with the YubiKey 5 plugged in, run
   `pamu2fcfg -o pam://sortofasian -i pam://sortofasian`. The format is in
   the comments of `modules/system/yubikey.nix`.
2. Add the output to `secrets/famine.yaml` as `pam-yubikeys`
   (`sops secrets/famine.yaml`).
3. Set `custom.yubikey.enable = true` in `hosts/Famine/default.nix`.

ssh and git signing need no secret: they use the `ssh:admin` key from the
agent (`ssh-keygen -K` + `ssh-add` where the YubiKey is plugged in). PAM
behaviour: [auth.md](../auth.md) (`custom.auth.desktopU2f`).

## Enrolling Famine in sops

To read charlie's password, anywhere the YubiKey is plugged in (needs the
PIV PIN and a touch):
`sops -d --extract '["charlie-password"]' secrets/famine.yaml`

### Procedure

1. **Host key.** On Famine, still on a pre-sops generation, run
   `sudo ssh-keygen -A`. It creates `/etc/ssh/ssh_host_ed25519_key` without
   enabling sshd. The key must exist before the first sops switch. Print the
   recipient:
   `nix run nixpkgs#ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub`
2. **Recipients.** On a branch, edit `.sops.yaml`:
   - add `- &famine <that age1… key>` to `keys:`;
   - add `- *famine` to the `secrets/common.yaml` rule;
   - change the `secrets/famine.yaml` rule to
     `[*admin_yubikey, *admin_backup, *famine]`;
   - delete the comment that says Famine is not a recipient.

   Then re-wrap both files with the backup key or the YubiKey
   (commands: [secrets.md](../secrets.md)):
   `sops updatekeys -y secrets/common.yaml secrets/famine.yaml`
3. **YubiKey (optional, needs the YubiKey 5 at Famine):** [YubiKey](#yubikey).
4. **Check decryption.** The pre-switch check `sopsDecrypt`
   (`modules/system/sops.nix`) aborts the switch, with nothing changed, if
   the host key can't decrypt both files. CI fails if a file's recipients
   don't match `.sops.yaml`. To check by hand before merging, on Famine
   from the branch checkout:
   ```sh
   for f in secrets/common.yaml secrets/famine.yaml; do
     sudo SOPS_AGE_KEY_CMD="$(nix build --no-link --print-out-paths nixpkgs#ssh-to-age)/bin/ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key" \
       "$(nix build --no-link --print-out-paths nixpkgs#sops)/bin/sops" -d "$f" >/dev/null && echo "$f OK"
   done
   ```
   Both must print OK. Use `SOPS_AGE_KEY_CMD` with `ssh-to-age`;
   `SOPS_AGE_SSH_PRIVATE_KEY_FILE` doesn't work.
5. **Deploy.** PR, CI, merge. Then on Famine:
   `sudo nixos-rebuild switch --flake .#Famine`. Log in as charlie with the
   `charlie-password` secret; use `admin` for sudo (charlie is not in
   wheel).
