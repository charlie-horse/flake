# Two-factor sudo (`custom.sudo2fa`)

`modules/system/sudo-2fa.nix`. Off by default; enabled per host in later
changes, m2mini first. When on, `sudo` (and polkit, where it runs) needs
**admin's password and** one second factor:

| Path | Second factor | Where it works |
| --- | --- | --- |
| rssh | `pam_rssh`: a signature from the FIDO2 resident key `ssh:admin` through the ssh-agent forwarded into the session | over SSH with `ssh -A`; the touch is on the YubiKey at the client |
| u2f | `pam_u2f`: a touch on a YubiKey plugged into the host (origin `pam://neurosis`) | the host's console |

admin's password is the same on every host and root on any host can read it
(`/run/secrets-for-users/admin-password`). With this on, that password alone
gives no root anywhere.

- [The PAM stack](#the-pam-stack)
- [Registering the YubiKey](#registering-the-yubikey)
- [Connecting with the forwarded agent](#connecting-with-the-forwarded-agent)
- [Rollout, one host at a time](#rollout-one-host-at-a-time)
- [Rollback](#rollback)
- [Lockout and recovery](#lockout-and-recovery)
- [Limits and caveats](#limits-and-caveats)

## The PAM stack

The auth section of `/etc/pam.d/sudo` with the option on (c4130, store
paths shortened):

```
auth [success=1 default=ignore] …/libpam_rssh.so auth_key_file=…-sudo-2fa-rssh-keys cue                          # sudo2fa-rssh (order 11698)
auth required                   …/pam_u2f.so appid=pam://neurosis authfile=…-sudo-2fa-u2f-keys cue origin=pam://neurosis userpresence=1 # sudo2fa-u2f (order 11699)
auth sufficient                 …/pam_unix.so likeauth try_first_pass                                            # unix (order 11700)
auth required                   …/pam_deny.so                                                                    # deny (order 12500)
```

How Linux-PAM runs it (`libpam/pam_dispatch.c`): a jump (`success=1`) only
skips lines; `required` records a failure and goes on; `sufficient` ends the
stack with success only if nothing failed before it, otherwise its success
is ignored and the recorded failure is returned; on failure it is ignored.

| Password | rssh | u2f | Run | Result |
| --- | --- | --- | --- | --- |
| right | ok | (skipped) | rssh jumps over u2f; unix ok, nothing failed | **allow** |
| right | fails | ok | rssh ignored; u2f ok; unix ok | **allow** |
| right | fails | fails | u2f records failure; unix ok but a required failed | deny |
| wrong | ok | (skipped) | unix fails (ignored); pam_deny | deny |
| wrong | fails | ok | unix fails; pam_deny | deny |
| wrong | fails | fails | u2f failure; unix fails; pam_deny | deny |

"rssh fails" covers: no `SSH_AUTH_SOCK` (pam_rssh returns AUTHINFO_UNAVAIL),
an agent without the `ssh:admin` key (AUTH_ERR, e.g. a cloud session's
agent), no touch before the YubiKey times out, a bad option (SYSTEM_ERR).
All map to `default=ignore`, so pam_u2f becomes required. With no YubiKey
plugged into the host, pam_u2f finds no authenticator and fails at once (no
wait). sudo still asks for the password afterwards and retries the whole
stack up to three times.

What you see: rssh path, `Please touch the device.` (touch the YubiKey on
your client), then `[sudo] password for admin:`. Console path, `Please touch
the FIDO authenticator.`, then the password.

Guards (evaluation fails otherwise):

- the u2f mapping must hold exactly one `admin:…` line (the placeholder in
  the repo has none, so enabling before registration fails);
- `sudo2fa-rssh`, `sudo2fa-u2f` and a `sufficient` `unix` rule must be
  adjacent in that order (`success=1` skips exactly one line);
- every other enabled auth rule must be `required`, `requisite` or
  `optional`. NixOS's own factor rules (`u2f`, `rssh`, `ssh_agent_auth`,
  `fprintd`, `howdy`, `p11`, `yubico`, `ussh`, `systemd_home`) are forced off
  on these services, so for example Famine's `sudo.u2fAuth` cannot make a
  touch replace the password;
- the service's `text` must not be overridden;
- sudo, not sudo-rs; no `NOPASSWD`/`!authenticate`, and
  `wheelNeedsPassword` stays true (those skip PAM auth and both factors).

Never add `nouserok` or `alwaysok` to pam_u2f: either can turn a failed touch
into PAM_IGNORE or success, and a `required` IGNORE is not a failure.

Services: `custom.sudo2fa.services`, by default `sudo`, plus `polkit-1` where
polkit runs (m2mini today). Without it, polkit (pkexec, run0) gives wheel
root with the password alone. Over SSH the polkit agent usually has no
`SSH_AUTH_SOCK`, so polkit needs the console YubiKey; use sudo instead.
sudo is built without `--with-pam-login`, so `sudo -i` and `sudoedit` use
`/etc/pam.d/sudo` too.

The module also sets `Defaults env_keep+=SSH_AUTH_SOCK` in sudoers: pam_rssh
finds the agent through `SSH_AUTH_SOCK`, and its README requires this line
for sudo. Commands run with sudo therefore see the forwarded agent too.

The key files are store paths (root-owned, read-only), never admin's
`authorized_keys`: a key file admin could write would let anything running
as admin add its own key.

- rssh keys: `custom.sudo2fa.rsshKeys`, by default the FIDO2 (`sk-`) keys
  of admin's SSH login (`users.users.admin.openssh.authorizedKeys.keys`,
  set in `modules/system/admin.nix`), today only `ssh:admin`; replacing or
  adding a key there updates both.
  pam_rssh 1.2.0 (nixos-26.05) supports `sk-ssh-ed25519@openssh.com` and
  `sk-ecdsa-sha2-nistp256@openssh.com` keys (it rebuilds the FIDO
  signed message from the key's application, `ssh:admin`).
- u2f mapping: `modules/system/sudo-2fa-u2f-keys` (public data).

## Registering the YubiKey

Once, from any machine with the YubiKey 5 (serial 19830800) plugged in.
`origin`/`appid` are fixed (`pam://neurosis`), so one registration works on
every host:

```sh
nix shell nixpkgs#pam_u2f -c pamu2fcfg -u admin -o pam://neurosis -i pam://neurosis
# touch the key; prints one line:
# admin:<KeyHandle>,<UserKey>,es256,+presence
```

(pamu2fcfg needs read/write access to the key's `/dev/hidraw*` device; if
it reports no device as a normal user, run it with sudo.) Put that
line in `modules/system/sudo-2fa-u2f-keys` under the comment, commit on a
branch, CI, merge.

A **backup YubiKey** is strongly advised before enabling anywhere (see
[Lockout and recovery](#lockout-and-recovery)): register it with
`pamu2fcfg -n -o pam://neurosis -i pam://neurosis` and append its
`:<KeyHandle>,<UserKey>,es256,+presence` to the same line, and add its
`ssh` resident key to admin's authorized keys in `modules/system/admin.nix`
(login, and through the default of `custom.sudo2fa.rsshKeys` also rssh).

## Connecting with the forwarded agent

The agent on your client must hold the `ssh:admin` key: `ssh-add -K` loads
the YubiKey's resident keys (asks for the FIDO PIN), or `ssh-add` the key
handle file. Check with `ssh-add -L | grep ssh:admin`. Then:

```sh
ssh -A admin@m2mini            # Tailscale SSH (MagicDNS name, port 22 on the tailnet IP)
ssh -A admin@<LAN address>     # plain OpenSSH (sshd), authenticates with the ssh:admin key
# on the host:
echo "$SSH_AUTH_SOCK"; ssh-add -L    # must list the ssh:admin key
sudo -v                              # touch at the client, then the password
```

Tailscale SSH: tailscaled supports agent forwarding
(`ssh/tailssh/process_unix.go`, `handleSSHAgentForwarding`): it forwards the
agent when the client asks (`-A`) and the control plane's SSH action for the
connection has `AllowAgentForwarding` set, unless tailscaled runs with
`TS_SSH_DISABLE_FORWARDING` (the servers do not). Whether the tailnet's SSH
rule grants it is decided by Tailscale's control plane and cannot be seen in
this repo: **check it once** with the commands above. If `SSH_AUTH_SOCK` is
empty over Tailscale SSH, use plain OpenSSH: Tailscale SSH takes over port 22
on the tailnet address, so connect to the host's LAN address, where sshd
accepts the `ssh:admin` key.

Only forward the agent to the host you are working on, and touch the
YubiKey only when you started the sudo yourself: root on that host can ask
your agent for signatures while you are connected. The challenge pam_rssh
signs is a random nonce not bound to a host, so a touch given to a
compromised host could be spent on sudo elsewhere. `ssh-add -c` (confirm
each use) narrows this.

**Cloud sessions cannot sudo on a host with this on**: they have neither the
YubiKey nor an agent holding `ssh:admin`. The `sudo -S` flow in
`CLAUDE.md` stops working there; the user runs sudo.

## Rollout, one host at a time

Before the first host: register the YubiKey (and a backup), confirm agent
forwarding works on the host (previous section), and know the host's
console access.

Per host, m2mini first, then r440, then c4130 (outside its GPU window, GC
first as usual):

1. In the repo, on a branch: `custom.sudo2fa.enable = true;` in
   `hosts/<host>/configuration.nix`. CI, merge.
2. **Session A** (keep it open until step 5 is done): SSH in, pull, and
   open a root shell before switching, so a broken sudo cannot strand you:
   ```sh
   cd /etc/nixos && git pull
   sudo -i                     # root shell, still password-only
   nixos-rebuild switch --flake /etc/nixos#<host>   # m2mini: --override-input m2mini-vendorfw path:/boot/vendorfw
   ```
   Then run the etcd health check from `docs/cluster.md`.
3. **Session B**, new, with `ssh -A`: `sudo -k; sudo -v` must ask for the
   touch at the client, then the password, and succeed. `sudo -k; sudo -v`
   with a wrong password and a touch must fail.
4. **Session C**, new, **without** `-A` (`ssh -a`): `sudo -k; sudo -v` must
   fail even with the right password (no YubiKey on the host).
5. **Console** (m2mini: keyboard and screen, or whatever console the host
   has), YubiKey plugged into the host: log in as admin, `sudo -v`, touch,
   password: must succeed. On m2mini also `pkexec true` (polkit-1) should
   ask for the touch and the password.
6. Only now close session A's root shell. Record the result in
   `docs/cluster.md`.

If step 3 or 5 fails, roll back from session A (next section) before
closing anything.

## Rollback

- From a root shell you still have (session A):
  `nixos-rebuild switch --rollback`, or switch a commit that sets
  `custom.sudo2fa.enable = false;`.
- With sudo still working through either factor: revert the enabling
  commit in the repo (branch, CI, merge), `git pull`, switch.
- From the console: pick the previous generation in the boot menu
  (systemd-boot on c4130/r440, GRUB on m2mini). That generation's
  `/etc/pam.d/sudo` asks for the password only; then switch a fixed
  commit. **Only while that generation exists**: c4130's GC rule
  (`--delete-generations +2`) keeps just the previous generation, so after
  the second switch with the option on, there is no password-only
  generation left there.

## Lockout and recovery

Both factors live on the same YubiKey (`ssh:admin` is a resident key on it,
and the pam_u2f credential too). Losing it, or a broken key file, means no
sudo on every host that has this on.

1. **Prevent it**: register a backup YubiKey for both paths (above) and keep
   it offline. Keep at least one host's console reachable.
2. **Key lost, backup exists**: sudo with the backup, remove the lost key's
   lines (u2f mapping, admin's authorized keys, which rsshKeys follows) in
   the repo, switch every host.
3. **Key lost, no backup, password-only generation still present**: console,
   boot the older generation, `sudo` with the password, switch a commit with
   `custom.sudo2fa.enable = false;` (or new keys). Note: the old generation
   is not the default boot entry; booting it does not change the default.
4. **No such generation**: physical access with rescue media (NixOS
   installer on c4130/r440; on m2mini an Asahi-capable USB installer).
   Mount the root filesystem, `nixos-enter --root /mnt`, and as root
   replace the `/etc/pam.d/sudo` symlink with a file holding the stock
   stack (`auth sufficient pam_unix.so likeauth try_first_pass` +
   `auth required pam_deny.so`, plus the account/password/session lines
   from the current file). It lasts until the next activation: boot, sudo
   with the password, switch a commit that disables the option or adds the
   new key. (The systemd-boot editor is on, but root is locked, so
   emergency/rescue targets give no shell; use the media.)
5. **Broken key file or bad u2f line but the agent path works**: sudo with
   `ssh -A`, fix the repo, switch. The evaluation guard catches a missing or
   malformed mapping before any switch, not a wrong one.

## Limits and caveats

- **sshd is keys only** on the servers (`modules/server/default.nix`:
  `PasswordAuthentication` and `KbdInteractiveAuthentication` off), so a
  leaked password gives no shell over plain SSH either.
- **Prerequisite: a second FIDO2 key.** Both factors and admin's SSH login
  live on YubiKey #19830800. Do not enable `custom.sudo2fa` on any host until
  a second key is registered for u2f (`u2fKeysFile`) and in admin's
  `openssh.authorizedKeys` (login, and rssh through `rsshKeys`' default)
  (decided 2026-11).
- Console login as admin needs only the password (by design, for
  recovery); sudo on the console then needs the YubiKey touch.
- pam_rssh 1.2.0 does not check the user-presence bit of the FIDO signature;
  the touch is enforced by the client (the `ssh:admin` key was made without
  `no-touch-required`, so the agent requests a touch for each signature).
- Famine (nixpkgs-unstable pin: pam_rssh 1.2.0-rc2, pam_u2f 1.3.0) imports
  the module with modules/ wholesale; it is off there. If ever enabled, the
  rssh `cue` option is left out (rc2 does not know it) and Famine's
  `sudo.u2fAuth` rule is forced off for sudo.
