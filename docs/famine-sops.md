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
| `charlie-password` | charlie's new Famine login password, random. Not deployed; it's stored so you can read it |
| `charlie-password-hash` | yescrypt hash of the above, deployed with `neededForUsers` |

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

   Then re-wrap both files. This needs the YubiKey (on c4130:
   `ssh admin@c4130`, which has pcscd and the plugin) or the backup key:
   `sops updatekeys -y secrets/common.yaml secrets/famine.yaml`
3. **YubiKey secrets (optional, needs both YubiKeys at Famine).**
   - `pam-yubikeys`: run `pamu2fcfg -o pam://sortofasian -i pam://sortofasian`,
     then run `pamu2fcfg -n -o pam://sortofasian -i pam://sortofasian` for the
     second key and append its output to the same line.
   - `ssh-yubikey-5`, `ssh-yubikey-5c`: if the keys are resident, run
     `ssh-keygen -K`; otherwise make new
     `ssh-keygen -t ed25519-sk -O resident` keys and update GitHub.
   - Add the three values with `sops secrets/famine.yaml`, then set
     `custom.yubikey.enable = true` in `hosts/Famine/default.nix`. The
     comments in `modules/system/yubikey.nix` give the exact formats.
4. **Check that decryption works before switching.** On Famine, from the
   branch checkout:
   ```sh
   for f in secrets/common.yaml secrets/famine.yaml; do
     sudo SOPS_AGE_KEY_CMD="$(nix build --no-link --print-out-paths nixpkgs#ssh-to-age)/bin/ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key" \
       "$(nix build --no-link --print-out-paths nixpkgs#sops)/bin/sops" -d "$f" >/dev/null && echo "$f OK"
   done
   ```
   Both must print OK. (`SOPS_AGE_SSH_PRIVATE_KEY_FILE` didn't work with
   sops 3.13 here; `SOPS_AGE_KEY_CMD` + `ssh-to-age` does.)
5. **Deploy.** Open a PR, wait for CI, and merge. Then on Famine:
   `sudo nixos-rebuild switch --flake .#Famine`. Log in as charlie with the
   password from `charlie-password`; use `admin` for sudo.
6. **Clean up.** Once Famine's netrc works from sops, the netrc is no longer
   needed in `r440:/root/nix-cache-setup/`. Shred that directory if every
   other host has switched too (`docs/cluster.md`, "Secrets (all of them)").

## Open choices

- **charlie's Famine password.** `custom.user.keepPassword` (in
  `modules/system/user.nix`, default true) keeps it for the greeter and
  hyprlock. Set it to false only if Famine gets another login method.
- **sudo on Famine.** charlie is no longer in wheel, so sudo needs `admin`.
