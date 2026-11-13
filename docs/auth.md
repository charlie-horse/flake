# Authentication (`custom.auth`)

All authentication policy for every host is in one module,
`modules/system/auth/default.nix`. It covers sshd, sudo, polkit, the console
and the desktop YubiKey. The servers import it from `modules/server/default.nix`,
and Famine gets it with `modules/` wholesale, so each host imports it exactly
once. Accounts (admin, root locked, charlie on Famine) are separate, in
`modules/system/admin.nix` and `modules/system/user.nix`.

- [Options](#options)
- [What each service asks for](#what-each-service-asks-for)
- [Hardware factor: the PAM stacks](#hardware-factor-the-pam-stacks)
- [Registering the keys](#registering-the-keys)
- [Clients: forwarding the agent](#clients-forwarding-the-agent)
- [Rollout, one host at a time](#rollout-one-host-at-a-time)
- [Lockout and recovery](#lockout-and-recovery)
- [Caveats](#caveats)

## Options

| Option | Default | Effect |
| --- | --- | --- |
| `custom.auth.sshd.keysOnly` | `true` | sshd: `PasswordAuthentication` and `KbdInteractiveAuthentication` off, wherever sshd runs (the servers; Famine runs no sshd) |
| `custom.auth.hardwareFactor.enable` | `false` | the hardware-key design below (servers; enabled per host later) |
| `custom.auth.hardwareFactor.sudoServices` | `[ "sudo" ]`, plus `"polkit-1"` where polkit runs | one hardware factor, no password |
| `custom.auth.hardwareFactor.loginServices` | `[ "login" ]` | password AND a u2f touch |
| `custom.auth.hardwareFactor.rsshKeys` | admin's `sk-` SSH login keys (`modules/system/admin.nix`) | keys pam_rssh accepts from the forwarded agent |
| `custom.auth.hardwareFactor.u2fKeysFile` | `modules/system/auth/u2f-keys` | pam_u2f mapping (`pamu2fcfg` output, public) |
| `custom.auth.desktopU2f.enable` | `false`; set by `custom.yubikey.enable` | Famine: pam_u2f as an alternative to the password |

`custom.yubikey.enable` (`modules/system/yubikey.nix`) still owns the desktop
YubiKey sops secrets (`pam-yubikeys`, `ssh-yubikey-5`) and links
`pam-yubikeys` to `~/.config/Yubico/u2f_keys`. It turns on
`custom.auth.desktopU2f` for the PAM side. sudo always has
`wheelNeedsPassword = true`: sudo authenticates wheel through PAM. With the
hardware factor on, PAM then asks for the key and not the password.
`hardwareFactor` and `desktopU2f` cannot both be on.

## What each service asks for

| Service | Both off (today, every host) | `hardwareFactor.enable` (servers) | `desktopU2f.enable` (Famine) |
| --- | --- | --- | --- |
| sshd (plain SSH, LAN port 22) | a key only | same | same |
| Tailscale SSH | tailnet identity; PAM auth skipped (`login -f`) | same | same |
| sudo | admin's password | rssh **or** u2f, **no password** | password **or** u2f touch |
| polkit-1 (pkexec, run0) | admin's password | rssh **or** u2f, **no password** | password **or** u2f touch |
| login (local console) | password | password **and** u2f touch | password **or** u2f touch |
| su | password (root is locked) | unchanged | password **or** u2f touch |
| greeter, hyprlock (Famine) | charlie's password | (not on Famine) | password **or** u2f touch |

- **rssh**: `pam_rssh` checks for a signature from the `ssh:admin` FIDO2
  resident key, made through the ssh-agent forwarded into the session. The
  touch happens on the YubiKey at the client.
- **u2f**: `pam_u2f` checks for a touch on a YubiKey plugged into the host
  (origin `pam://neurosis`).
- **desktopU2f "or"**: this is NixOS's `security.pam.u2f.enable`, which puts a
  `sufficient` pam_u2f in every PAM service on Famine (origin
  `pam://sortofasian`). That is unchanged from the former
  `modules/system/pam.nix`.

The hardware factor's aim: admin's password is the same on every host, and
root on any host can read it (`/run/secrets-for-users/admin-password`). With
the factor on, the password gives no root anywhere, and at the console it
is not enough alone.

## Hardware factor: the PAM stacks

`/etc/pam.d/sudo` and `/etc/pam.d/polkit-1` (m2mini), auth section. This is
c4130 and m2mini forced on with a dummy mapping, store paths shortened:

```
auth sufficient /nix/store/…-pam_rssh-1.2.0/lib/libpam_rssh.so auth_key_file=/nix/store/…-auth-rssh-keys cue # hw-rssh (order 12498)
auth sufficient /nix/store/…-pam_u2f-1.4.0/lib/security/pam_u2f.so appid=pam://neurosis authfile=/nix/store/…-auth-u2f-keys cue origin=pam://neurosis userpresence=1 # hw-u2f (order 12499)
auth required /nix/store/…-linux-pam-1.7.2/lib/security/pam_deny.so # deny (order 12500)
```

`/etc/pam.d/login`, auth section:

```
auth required /nix/store/…-pam_u2f-1.4.0/lib/security/pam_u2f.so appid=pam://neurosis authfile=/nix/store/…-auth-u2f-keys cue origin=pam://neurosis userpresence=1 # hw-u2f (order 11699)
auth sufficient /nix/store/…-linux-pam-1.7.2/lib/security/pam_unix.so likeauth nullok try_first_pass # unix (order 11700)
auth required /nix/store/…-linux-pam-1.7.2/lib/security/pam_deny.so # deny (order 12500)
```

How Linux-PAM runs these stacks (`libpam/pam_dispatch.c`):

- `sufficient` ends the stack with success, but only if no earlier `required`
  failed. When a `sufficient` module fails, PAM ignores it and goes on.
- `required` records a failure and goes on.

**sudo / polkit-1** (pam_unix is not in the stack, so the password is never
asked for and never helps):

| rssh | u2f | Run | Result |
| --- | --- | --- | --- |
| ok | (not run) | rssh `sufficient` ends the stack | **allow** |
| fails | ok | rssh ignored; u2f `sufficient` | **allow** |
| fails | fails | both ignored; pam_deny | deny |

**login** (local console):

| Password | u2f | Run | Result |
| --- | --- | --- | --- |
| right | ok | u2f ok; unix `sufficient`, nothing failed | **allow** |
| right | fails | u2f records failure; unix ok but a `required` failed | deny |
| wrong | ok | unix fails (ignored); pam_deny | deny |
| wrong | fails | pam_deny | deny |

What counts as an rssh failure (all are ignored, then u2f runs):

| Situation | pam_rssh returns |
| --- | --- |
| no `SSH_AUTH_SOCK` | AUTHINFO_UNAVAIL |
| an agent without the `ssh:admin` key (only a plain `ssh-ed25519` key, a cloud session's agent) | AUTH_ERR, logging "None of these keys passed authentication" |
| no touch before the YubiKey times out | AUTH_ERR |
| a bad option | SYSTEM_ERR |

pam_u2f fails at once when no FIDO device is plugged into the host. Its
loop has no wait (pam_u2f 1.4.0 `util.c`, `do_authentication`), so on a
host without a plugged-in key, sudo over SSH without an agent fails
quickly. With a key plugged into the host (the YubiKey normally sits in
c4130), u2f prints `Please touch the FIDO authenticator.` and waits for a
touch on that key.

On failure sudo still retries the stack three times and then says
`3 incorrect password attempts`, although no password was asked for.

Tailscale SSH sessions start the shell with `login -f`. shadow's `login`
skips `pam_authenticate` with `-f` (`src/login.c`), so the login change
only affects the local ttys. sshd (keys only) does not use these stacks.

Evaluation fails if any of these guards is broken:

- **u2f mapping**: it must be one `admin:` line with at least **two**
  credentials (the second-key prerequisite). The repo's placeholder has
  none.
- **rssh keys**: rsshKeys must not be empty. Fewer than two gives a
  warning.
- **Stack shape**: sudo/polkit must end in `hw-rssh` (sufficient),
  `hw-u2f` (sufficient), `deny`. login must end in `hw-u2f` (required),
  `unix` (sufficient), `deny`. Every rule before them must be `required`,
  `requisite` or `optional`.
- **No password path for sudo/polkit**: no pam_unix rule may be in their
  auth stack.
- **NixOS's own factor rules are forced off on these services**: `u2f`,
  `rssh`, `ssh_agent_auth`, `fprintd`, `howdy`, `p11`, `yubico`, `ussh`,
  `systemd_home`. On sudo/polkit, `unix` and `unix-early` are forced off
  too.
- **Overrides**: the generated `text` must not be overridden.
- **sudo itself**: it must be sudo, not sudo-rs. No `NOPASSWD` and no
  `!authenticate`, since either skips PAM and with it the key.
- **Accounts**: admin must be the only wheel account. The mapping and the
  keys are admin's; a server still in stage 1 of charlie's removal fails
  this check.

Never add `nouserok` or `alwaysok` to pam_u2f. Either can turn a failed
touch into IGNORE or success.

The key files are store paths (root-owned, read-only), never admin's
`authorized_keys`. pam_rssh 1.2.0 (nixos-26.05) supports
`sk-ssh-ed25519@openssh.com`: `sign_verify.rs` rebuilds the FIDO signed
message from the key's application, `ssh:admin`. sudoers gets
`Defaults env_keep+=SSH_AUTH_SOCK` (pam_rssh's README requires it), so
commands run with sudo also see the forwarded agent. sudo is built without
`--with-pam-login`, so `sudo -i` and `sudoedit` use `/etc/pam.d/sudo` as
well.

## Registering the keys

**Prerequisite: two FIDO2 keys.** The YubiKey 5 (serial 19830800) plus a
second one, kept apart. Evaluation refuses `hardwareFactor.enable` until
the mapping holds two credentials.

1. **u2f**: `origin` and `appid` are fixed (`pam://neurosis`), so one
   registration works on every host. On any machine with the key plugged
   in:

   ```sh
   nix shell nixpkgs#pam_u2f -c pamu2fcfg -u admin -o pam://neurosis -i pam://neurosis   # key 1, touch
   nix shell nixpkgs#pam_u2f -c pamu2fcfg -n -o pam://neurosis -i pam://neurosis         # key 2, touch
   ```

   Write ONE line under the comment in `modules/system/auth/u2f-keys`: the
   first output (`admin:<KH1>,<PK1>,es256,+presence`) followed directly by
   the second (`:<KH2>,<PK2>,es256,+presence`). If pamu2fcfg finds no
   device as a normal user, run it with sudo.

2. **rssh**: make an `ssh:admin` resident key on the second key
   (`ssh-keygen -t ed25519-sk -O resident -O application=ssh:admin`). Add
   its public key to `adminAuthorizedKeys` in `modules/system/admin.nix`.
   rsshKeys follows that list, and the same key then also logs in over SSH.

## Clients: forwarding the agent

The agent on the client must hold the `ssh:admin` **sk** key. A plain
`ssh-ed25519` key does not count. Check with `ssh-add -L`: the line must
start with `sk-ssh-ed25519@openssh.com` and end in `ssh:admin`.

**Windows** (tested 2026-11-13, Win32-OpenSSH agent):

1. `ssh -V` must be OpenSSH 8.9 or newer (FIDO2 support in the agent).
2. Start the agent and keep it running (PowerShell as Administrator):
   `Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent`.
3. In `%USERPROFILE%\.ssh`, with the YubiKey plugged in, run `ssh-keygen -K`
   (FIDO PIN, touch). It writes the resident-key stub
   `id_ed25519_sk_rk_admin` (and `.pub`).
4. Load it: `ssh-add .\id_ed25519_sk_rk_admin`.
5. In `~/.ssh/config`, for the hosts: `ForwardAgent yes` (or use `ssh -A`).

The failure seen before step 4: the agent offered only a plain
`ssh-ed25519` key. pam_rssh logged "None of these keys passed
authentication" (`journalctl -b | grep -i rssh`), and sudo said
"incorrect password" although none was asked for.

**Linux/macOS**: `ssh-add -K` loads the YubiKey's resident keys, or
`ssh-add` the key handle file. Then `ssh -A`.

On the host:

```sh
echo "$SSH_AUTH_SOCK"; ssh-add -L     # must list the sk-…ssh:admin key
sudo -k; sudo -v                      # "Please touch the device." -> touch at the client
```

**Tailscale SSH** forwards the agent: `handleSSHAgentForwarding` in
`ssh/tailssh` forwards it when the client asks (`-A`) and the control
plane's SSH action has `AllowAgentForwarding`, unless tailscaled runs with
`TS_SSH_DISABLE_FORWARDING` (the servers do not). Whether the tailnet's SSH rule grants it
is the control plane's; `echo "$SSH_AUTH_SOCK"` above shows it. Plain OpenSSH to the LAN address works too: sshd accepts
the `ssh:admin` key, since Tailscale SSH takes port 22 on the tailnet
address.

**Relay caveat.** Forward the agent only to the host you are working on,
and touch the key only for a sudo you started. Root on a host you are
connected to can ask your agent for signatures. The challenge pam_rssh
signs is a random nonce, not bound to a host, so a touch given to a
compromised host could be spent on sudo elsewhere. `ssh-add -c` (confirm
each use) narrows this.

**Cloud sessions cannot sudo** on a host with the factor on: they have
neither key. CLAUDE.md already has the user run sudo.

## Rollout, one host at a time

Prerequisites:

- both keys registered (above);
- agent forwarding checked on the host;
- console access to the host known.

The order is m2mini, r440, then c4130 (outside its GPU window, GC first as
usual). Per host:

1. **Enable it.** In the repo, on a branch, set
   `custom.auth.hardwareFactor.enable = true;` in
   `hosts/<host>/configuration.nix`. CI, merge.
2. **Session A: root shell and switch.** Keep this session open until step
   6. SSH in, pull, and open a root shell **before** switching, while sudo
   still takes the password:
   ```sh
   cd /etc/nixos && git pull
   sudo -i
   nixos-rebuild switch --flake /etc/nixos#<host>   # m2mini: --override-input m2mini-vendorfw path:/boot/vendorfw
   ```
   Then run the etcd health check (`docs/cluster.md`).
3. **Session B: rssh path.** In a new session with the agent forwarded,
   `sudo -k; sudo -v` asks for a touch at the client and no password, and
   succeeds.
4. **Session C: no agent.** In a new session with `ssh -a` (no agent) and no
   key plugged into the host, `sudo -k; sudo -v` must fail.
5. **Console.** On the host's console, with a key plugged in:
   - login as admin asks for the touch and the password, and succeeds;
   - without the touch it fails;
   - `sudo -v` there succeeds with only a touch;
   - on m2mini, `pkexec true` succeeds with only a touch.
6. **Finish.** Close session A's root shell, and note the state in
   `docs/cluster.md`.

If step 3 or 5 fails, roll back from session A with
`nixos-rebuild switch --rollback`, or switch a commit with the option off.

## Lockout and recovery

With the factor on, a host needs a key for sudo **and** for console login.
The password alone opens nothing there.

- **One key lost, the other at hand.** Use the other key for sudo (rssh or
  u2f). Then remove the lost key's credential from `u2f-keys` and its
  public key from `modules/system/admin.nix`, and switch every host.
  Register a replacement before relying on a single key.
- **Both keys lost or broken, a pre-factor generation still on the host.**
  Use the boot menu (systemd-boot on c4130/r440, GRUB on m2mini) to boot
  the last generation without the factor. There, sudo and the console take
  the password again. Switch a commit with
  `custom.auth.hardwareFactor.enable = false;`. c4130's GC rule
  (`--delete-generations +2`) keeps only the previous generation, so this
  route is gone after the second switch with the factor on.
- **No such generation.** You need physical access with rescue media: the
  NixOS installer on c4130/r440, or an Asahi-capable USB installer on
  m2mini.
  1. Mount the root filesystem and run `nixos-enter --root /mnt`.
  2. As root, replace the `/etc/pam.d/sudo` symlink with a file holding
     the stock stack: `auth sufficient pam_unix.so likeauth try_first_pass`
     and `auth required pam_deny.so`, plus the account/password/session
     lines of the current file.
  3. Boot, sudo with the password, and switch a commit that disables the
     factor or adds new keys. The edited file lasts until that activation.

  Emergency and rescue targets give no shell, because root is locked.

These cases are why the second key is a hard prerequisite.

## Caveats

- **The parked key is a u2f path for any admin shell.** The YubiKey
  normally sits in c4130. Anyone with an admin shell there (Tailscale SSH
  needs only tailnet identity) gets a working u2f path, and only a
  physical touch on c4130 is missing. Unplug the key from a host whose
  sudo should need your client-side touch only.
- **pam_rssh 1.2.0 does not check the FIDO user-presence bit.** The touch
  is enforced by the client, because the key was made without
  `no-touch-required`.
- **Famine's nixpkgs pin** has pam_rssh 1.2.0-rc2, which has no `cue`
  option; the module leaves it out there. The hardware factor is not meant
  for Famine (desktopU2f is).
