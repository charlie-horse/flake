# Authentication and host secrets

How each host decrypts its sops secrets and derives login passwords, and
the authentication policy (`custom.auth`: sshd, sudo, polkit, the console,
the optional hardware factor). The inventory of every secret is
[secrets.md](secrets.md); the cluster PKI is [pki.md](pki.md).

- [sops-nix on the hosts](#sops-nix-on-the-hosts)
- [custom.auth](#customauth)
  - [Options](#options)
  - [What each service asks for](#what-each-service-asks-for)
  - [Hardware factor: the PAM stacks](#hardware-factor-the-pam-stacks)
  - [Registering the keys](#registering-the-keys)
  - [Clients: forwarding the agent](#clients-forwarding-the-agent)
  - [Enabling the factor on a host](#enabling-the-factor-on-a-host)
  - [Lockout and recovery](#lockout-and-recovery)
  - [Caveats](#caveats)
- [Desktop YubiKey](#desktop-yubikey)

## sops-nix on the hosts

`modules/system/sops.nix`, on every host (desktops through `modules/`,
servers through `modules/server/default.nix`). Recipients are in
`.sops.yaml`; what each secret is and where it lives is
[secrets.md](secrets.md). Editing a sops file with the YubiKey (ad hoc,
pcscd on a server) is also there.

### Files

| File | Recipients | Used by |
| --- | --- | --- |
| `secrets/<hostname>.yaml` (lowercase, e.g. `c4130.yaml`, `famine.yaml`) | admins + that host (`famine.yaml`: admins only; Famine is not a recipient) | the default `sopsFile` of every `sops.secrets.<name>` |
| `secrets/common.yaml` | admins + every server (not Famine) | per secret, e.g. `admin-password` |
| `secrets/admin.yaml` | admins only, never deployed | e.g. the YubiKey PIV PUK |
| `secrets/pki/<node>.yaml`, `secrets/cluster-sa.yaml` | admins + that node / every control plane | the cluster PKI ([pki.md](pki.md#on-the-nodes-runsecretspki)) |
| `k8s/secrets/<ns>/<name>.sops.yaml` | admins + Flux | in-cluster only ([k8s/secrets.md](k8s/secrets.md)) |

The admins are `admin_yubikey` (age-plugin-yubikey, PIV slot 82 of the
YubiKey 19830800) and `admin_backup` (an offline passphrase-protected age
key); every rule has both, so any file can be recovered.

A host selects a file other than its own with
`sopsFile = builtins.path { path = "${inputs.self}/secrets/common.yaml"; name = "common.yaml"; }`.
Always through `builtins.path`: it copies that one file to the store, so a
host's closure references only its own sops files. Never a bare
`"${inputs.self}/secrets/..."` (every system then depends on the whole
flake source) or a relative `../../secrets` (breaks on the desktops, whose
`modules/` is a store copy of its own).

Edit a file with `sops secrets/<file>.yaml` from the dev shell
(`devenv.nix`: sops, age, age-plugin-yubikey, ssh-to-age). Secrets land in
`/run/secrets/` (with `neededForUsers`: `/run/secrets-for-users/`, before
users are created).

### Host keys and recipients

A host decrypts with its own SSH ed25519 host key
(`/etc/ssh/ssh_host_ed25519_key`), converted to an age identity at
activation. Its recipient in `.sops.yaml` is `ssh-to-age <
ssh_host_ed25519_key.pub`. No GnuPG and no RSA host keys.

- **After changing a recipient list**, re-encrypt the affected files with
  `sops updatekeys <file>`.
- **A reinstalled host** gets a new host key: update its `.sops.yaml`
  anchor (and `sshHostKey`), re-encrypt every file it reads, merge, all
  **before** its first switch, or admin has no password there.
- **The host key must exist before the first activation.** The servers'
  sshd makes it. Famine runs no sshd; its enrolment (`sudo ssh-keygen -A`,
  add the recipient, `sops updatekeys`) is in
  [hosts/famine.md](hosts/famine.md). For activations that skip the
  pre-switch check, an activation script makes a missing key (never
  touching an existing one, without enabling sshd) before sops-nix
  decrypts anything.

### Can this host decrypt?

Checked twice, automatically:

- **CI** (`.github/workflows/checks.yml`, secrets-guard): every sops file's
  age recipients equal its `.sops.yaml` rule, so no file was left
  un-re-encrypted after a recipient change. No keys needed.
- **On the host, before every switch/boot/test** (`system.preSwitchChecks.sopsDecrypt`):
  each sops file the new generation uses is decrypted with the host key (to
  `/dev/null`). Any failure, or a missing host key, aborts
  `switch-to-configuration` before the bootloader or activation is touched.
  `NIXOS_NO_CHECK=1` skips every pre-switch check; don't, unless you know
  why it failed.

### Login passwords (`custom.sopsPasswords`)

Used for admin (`modules/system/admin.nix`) and the desktop user
(`modules/system/user.nix`). The sops key holds the **plaintext** password.
admin's is `admin-password` in `secrets/common.yaml` (read it with
`sops -d --extract '["admin-password"]' secrets/common.yaml`); to change
it, edit that key and switch every host.

1. sops-nix decrypts it with `neededForUsers` to
   `/run/secrets-for-users/<key>` (ramfs, root 0400).
2. The activation script `sopsPasswordHashes` derives the yescrypt hash
   (`mkpasswd -m yescrypt --stdin`) into `/run/sops-password-hashes/<user>`
   (tmpfs, root 0600 in a root 0700 directory): the user's
   `hashedPasswordFile`. The current `/etc/shadow` hash is reused while it
   still matches, so an unchanged password keeps its salt.
3. nixpkgs' `users` script reads it. Order: `setupSecretsForUsers` →
   `sopsPasswordHashes` → `users`.

If the plaintext is missing or empty (decryption failed), the activation
fails loudly and the user's **previous** hash from `/etc/shadow` is written
instead; with immutable users a missing `hashedPasswordFile` would lock the
account. The hashes have their own directory, since sops-nix creates
`/run/secrets-for-users` only after a successful decryption; a failing
`setupSecretsForUsers` does not stop the activation, so this step still
runs. It needs the classic perl `users` script (no systemd-sysusers, no
userborn; asserted).

`users.mutableUsers = false` (`mkDefault`, `modules/system/admin.nix`):
`/etc/passwd`, `/etc/shadow` and `/etc/group` are rebuilt at every
activation, so `passwd` and `useradd` do not survive a switch, and root is
locked (`!`). `custom.server.legacyCharlie.enable`
(`modules/server/legacy-charlie.nix`, off on every server) makes users
mutable; nixpkgs then applies `hashedPasswordFile` only when it creates a
user.

**Lockout:** a host that cannot decrypt `secrets/common.yaml` has no admin
password and, with root locked, no sudo. The checks in
[Can this host decrypt?](#can-this-host-decrypt) refuse such a switch; if
decryption still fails at activation, the previous hash is kept.

## custom.auth

All authentication policy for every host is in one module,
`modules/system/auth/default.nix`. It covers sshd, sudo, polkit, the console
and the desktop YubiKey. The servers import it from `modules/server/default.nix`,
and Famine gets it with `modules/` wholesale, so each host imports it exactly
once.

### Options

| Option | Default | Effect |
| --- | --- | --- |
| `custom.auth.sshd.keysOnly` | `true` | sshd: `PasswordAuthentication` and `KbdInteractiveAuthentication` off, wherever sshd runs (the servers; Famine runs no sshd) |
| `custom.auth.hardwareFactor.enable` | `false` | the hardware factor below (servers, per host) |
| `custom.auth.hardwareFactor.sudoServices` | `[ "sudo" ]`, plus `"polkit-1"` where polkit runs | one hardware factor, no password |
| `custom.auth.hardwareFactor.loginServices` | `[ "login" ]` | password AND a u2f touch |
| `custom.auth.hardwareFactor.rsshKeys` | admin's `sk-` SSH login keys (`modules/system/admin.nix`) | keys pam_rssh accepts from the forwarded agent |
| `custom.auth.hardwareFactor.u2fKeysFile` | `modules/system/auth/u2f-keys` | pam_u2f mapping (`pamu2fcfg` output, public) |
| `custom.auth.desktopU2f.enable` | `false`; set by `custom.yubikey.enable` | Famine: pam_u2f as an alternative to the password |

`custom.yubikey.enable` ([Desktop YubiKey](#desktop-yubikey)) turns on
`custom.auth.desktopU2f` for the PAM side. sudo always has
`wheelNeedsPassword = true`: sudo authenticates wheel through PAM. With the
hardware factor on, PAM then asks for the key and not the password.
`hardwareFactor` and `desktopU2f` cannot both be on.

### What each service asks for

| Service | Both off (default) | `hardwareFactor.enable` (servers) | `desktopU2f.enable` (Famine) |
| --- | --- | --- | --- |
| sshd (plain SSH, LAN port 22) | a key only | same | same |
| Tailscale SSH | tailnet identity; PAM auth skipped (`login -f`) | same | same |
| sudo | admin's password | rssh **or** u2f, **no password** | password **or** u2f touch |
| polkit-1 (pkexec, run0) | admin's password | rssh **or** u2f, **no password** | password **or** u2f touch |
| login (local console) | password | password **and** u2f touch | password **or** u2f touch |
| su | password (root is locked) | unchanged | password **or** u2f touch |
| greeter, hyprlock (Famine) | the desktop user's password | (not on Famine) | password **or** u2f touch |

- **rssh**: `pam_rssh` checks for a signature from the `ssh:admin` FIDO2
  resident key, made through the ssh-agent forwarded into the session. The
  touch happens on the YubiKey at the client.
- **u2f**: `pam_u2f` checks for a touch on a YubiKey plugged into the host
  (origin `pam://neurosis`).
- **desktopU2f "or"**: this is NixOS's `security.pam.u2f.enable`, which puts a
  `sufficient` pam_u2f in every PAM service on Famine (origin
  `pam://sortofasian`).

With the factor on, admin's password (the same on every host, and readable
by root at `/run/secrets-for-users/admin-password`) gives no root anywhere,
and at the console it is not enough alone.

### Hardware factor: the PAM stacks

`/etc/pam.d/sudo` and `/etc/pam.d/polkit-1` (m2mini), auth section, with
the factor on (store paths shortened):

```
auth sufficient /nix/store/…-pam_rssh-1.2.0/lib/libpam_rssh.so auth_key_file=/nix/store/…-auth-rssh-keys cue # hw-rssh (order 12498)
auth sufficient /nix/store/…-pam_u2f-1.4.0/lib/security/pam_u2f.so appid=pam://neurosis authfile=/nix/store/…-auth-u2f-keys cue origin=pam://neurosis userpresence=1 # hw-u2f (order 12499)
auth required /nix/store/…-linux-pam-1.7.2/lib/security/pam_deny.so # deny (order 12500)
```

`/etc/pam.d/login`, auth section:

```
auth required /nix/store/…-pam_u2f-1.4.0/lib/security/pam_u2f.so appid=pam://neurosis authfile=/nix/store/…-auth-u2f-keys cue origin=pam://neurosis userpresence=1 # hw-u2f (order 11699)
auth sufficient /nix/store/…-linux-pam-1.7.2/lib/security/pam_unix.so likeauth try_first_pass # unix (order 11700)
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

With the factor on, login's pam_unix also loses NixOS's default `nullok`
(an empty password is never accepted at the console); off, it is unchanged.

**polkit-1** stays in `sudoServices` wherever polkit runs (m2mini). Over
SSH, polkit's agent helper usually does not see `SSH_AUTH_SOCK`, so
`pkexec`/`run0` there needs a key plugged into the host; use sudo over SSH.

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
quickly. While a key is plugged into the host (only ever deliberately and
for a moment; see [Caveats](#caveats)), u2f prints `Please touch the FIDO
authenticator.` and waits for a touch on that key.

On failure sudo still retries the stack three times and then says
`3 incorrect password attempts`, although no password was asked for.

Tailscale SSH sessions start the shell with `login -f`. shadow's `login`
skips `pam_authenticate` with `-f` (`src/login.c`), so the login change
only affects the local ttys. sshd (keys only) does not use these stacks.

Evaluation fails if any of these guards is broken:

- **u2f mapping**: it must be one `admin:` line with at least **two**
  credentials (the second-key prerequisite). The repo's placeholder has
  none.
- **rssh keys**: rsshKeys must hold at least **two** `sk-` keys, one per
  FIDO2 key (the second-key prerequisite, rssh side).
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
- **Accounts**: admin must be the only wheel account (the mapping and the
  keys are admin's).

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

### Registering the keys

**Prerequisite: two FIDO2 keys.** The YubiKey 5 (serial 19830800) plus a
second one, kept apart. Evaluation refuses `hardwareFactor.enable` until
the u2f mapping holds two credentials AND rsshKeys holds two `sk-` keys
(both steps below, for both keys).

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

2. **rssh** (required): make an `ssh:admin` resident key on the second key
   (`ssh-keygen -t ed25519-sk -O resident -O application=ssh:admin`). Add
   its public key to `adminAuthorizedKeys` in `modules/system/admin.nix`.
   rsshKeys follows that list, and the same key then also logs in over SSH.

### Clients: forwarding the agent

The agent on the client must hold the `ssh:admin` **sk** key. A plain
`ssh-ed25519` key does not count. Check with `ssh-add -L`: the line must
start with `sk-ssh-ed25519@openssh.com` and end in `ssh:admin`.

Load it with `ssh-add -K` (YubiKey plugged in), or `ssh-add` the resident
key handle file `ssh-keygen -K` writes (Windows: `id_ed25519_sk_rk_admin`,
agent service running). Then `ssh -A` or `ForwardAgent yes`.

If the agent offers only a plain key, pam_rssh logs "None of these keys
passed authentication" (`journalctl -b | grep -i rssh`) and sudo says
"incorrect password" although none was asked for.

On the host:

```sh
echo "$SSH_AUTH_SOCK"; ssh-add -L     # must list the sk-…ssh:admin key
sudo -k; sudo -v                      # "Please touch the device." -> touch at the client
```

**Tailscale SSH** forwards the agent: `handleSSHAgentForwarding` in
`ssh/tailssh` forwards it when the client asks (`-A`) and the control
plane's SSH action has `AllowAgentForwarding`, unless tailscaled runs with
`TS_SSH_DISABLE_FORWARDING` (the servers do not). `echo "$SSH_AUTH_SOCK"`
above shows whether the tailnet's SSH rule grants it. Plain OpenSSH to the
LAN address works too (sshd accepts the `ssh:admin` key); Tailscale SSH
takes port 22 on the tailnet address.

**Relay caveat.** Forward the agent only to the host you are working on,
and touch the key only for a sudo you started. Root on a host you are
connected to can ask your agent for signatures. The challenge pam_rssh
signs is a random nonce, not bound to a host, so a touch given to a
compromised host could be spent on sudo elsewhere. `ssh-add -c` (confirm
each use) narrows this.

### Enabling the factor on a host

Prerequisites:

- both keys registered (above);
- agent forwarding checked on the host;
- console access to the host known.

One host at a time ([cluster.md, Changing a host](cluster.md#changing-a-host)):

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
6. **Finish.** Close session A's root shell.

If step 3 or 5 fails, roll back from session A with
`nixos-rebuild switch --rollback`, or switch a commit with the option off.

### Lockout and recovery

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

### Caveats

- **A key plugged into a host is a u2f path for any admin shell there.**
  The YubiKey (serial 19830800) travels with the user and is never parked
  in a host. Plugging it (or the second key) into a host, for the console
  or for sops work, is a deliberate, temporary act. While it is plugged in,
  any admin shell on that host (Tailscale SSH needs only tailnet identity)
  gets a touch-only u2f path to sudo: nothing but a physical touch is
  missing. Unplug it as soon as you are done.
- **pam_rssh 1.2.0 does not check the FIDO user-presence bit.** The touch
  is enforced by the client, because the key was made without
  `no-touch-required`.
- **Famine's nixpkgs pin** has pam_rssh 1.2.0-rc2, which has no `cue`
  option; the module leaves it out there. Famine uses desktopU2f, not the
  hardware factor.

## Desktop YubiKey

`custom.yubikey.enable` (`modules/system/yubikey.nix`, desktops; off by
default, and Famine sets it `false`) puts the per-user pam_u2f mapping on a
desktop and turns on `custom.auth.desktopU2f`:

- sops secret `pam-yubikeys` from the host's own file
  (`secrets/<hostname>.yaml`), owner the desktop user, 0400, linked to
  `~/.config/Yubico/u2f_keys` (pam_u2f's default authfile). One line,
  `<user>:<keyHandle>,<pubkey>,es256,+presence`, made at the machine with
  the YubiKey: `pamu2fcfg -o pam://sortofasian -i pam://sortofasian`.
- The key must exist in the host's sops file before enabling, or
  evaluation fails (sops-nix checks the file).
- No separate SSH identity: ssh and git signing use the `ssh:admin` FIDO2
  key from the agent (`modules/programs/ssh.nix`, `modules/programs/git.nix`).
