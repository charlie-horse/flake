# Authentication and host secrets

How to operate sops-nix on the hosts, login passwords and the
authentication policy (`custom.auth`, `modules/system/auth/`). What each
option sets is in the module. The inventory of every secret is
[secrets.md](secrets.md); the cluster PKI is [pki.md](pki.md).

Terms:

- **sops** encrypts secret files so they can live in git. Each file is
  encrypted to a list of **recipients** (public keys); any matching
  private key decrypts it. **sops-nix** decrypts them on a host at
  activation.
- **FIDO2 key**: a hardware security key such as a YubiKey. **pam_u2f**
  lets sudo and login ask for a touch on it; **rssh** (pam_rssh) lets sudo
  accept a signature from the key through a forwarded SSH agent.
- **The factor**: `custom.auth.hardwareFactor`, which makes sudo and
  console login require the key.

- [sops-nix on the hosts](#sops-nix-on-the-hosts)
- [custom.auth](#customauth)
  - [Registering the keys](#registering-the-keys)
  - [Clients: forwarding the agent](#clients-forwarding-the-agent)
  - [Enabling the factor on a host](#enabling-the-factor-on-a-host)
  - [Lockout and recovery](#lockout-and-recovery)
- [Desktop YubiKey](#desktop-yubikey)

## sops-nix on the hosts

Recipients are in `.sops.yaml`; the host module is `modules/system/sops.nix`.

- **Edit** a file with `sops secrets/<file>.yaml` from the dev shell.
- **After changing a recipient list**, re-encrypt the affected files with
  `sops updatekeys <file>`.
- **A host's recipient** is `ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub`.
- **A reinstalled host** gets a new host key: update its `.sops.yaml`
  anchor and its `sshHostKey` in `cluster/definition.nix`, re-encrypt every
  file it reads, merge, all **before** its first switch, or admin has no
  password there.
- **A file other than the host's own** is selected with
  `sopsFile = builtins.path { path = "${inputs.self}/secrets/<file>.yaml"; name = "<file>.yaml"; }`.
  Never a bare `"${inputs.self}/secrets/..."` (every system then depends on
  the whole flake source) or a relative `../../secrets` (fails on the
  desktops).
- **Pre-switch check.** A switch the host could not decrypt is refused
  (`system.preSwitchChecks.sopsDecrypt`). Don't skip it with
  `NIXOS_NO_CHECK=1` unless you know why it failed.
- **admin's password** is the plaintext sops key `admin-password` in
  `secrets/common.yaml` (`sops -d --extract '["admin-password"]' secrets/common.yaml`).
  To change it, edit that key and switch every host. Users are immutable:
  `passwd` and `useradd` do not survive a switch.
- **Lockout:** a host that cannot decrypt `secrets/common.yaml` has no
  admin password and, with root locked, no sudo. If decryption fails at
  activation anyway, the previous hash is kept.

## custom.auth

Rules:

- Never add `nouserok` or `alwaysok` to pam_u2f, and never give sudo
  `NOPASSWD` or `!authenticate`.
- **A key plugged into a host is a touch-only sudo path for any admin
  shell there.** Plug a YubiKey into a host only deliberately and briefly,
  and unplug it when done.
- **Forward the agent only to the host you are working on**, and touch the
  key only for a sudo you started: root on any host holding your agent can
  ask it for signatures. Use `ssh-add -c` (confirm each use) to limit this.
- With the factor on, use sudo over SSH, not `pkexec`/`run0`: polkit's
  agent usually does not see `SSH_AUTH_SOCK`.
- With the factor on, a failed sudo still says `3 incorrect password
  attempts` although no password was asked for. Check
  `journalctl -b | grep -i rssh`.

### Registering the keys

**Prerequisite: two FIDO2 keys**, the admin YubiKey plus a second one,
kept apart. Evaluation refuses `hardwareFactor.enable` until both steps
are done for both keys.

1. **u2f** (`origin` and `appid` are `pam://neurosis` on every host). On
   any machine with the key plugged in:

   ```sh
   nix shell nixpkgs#pam_u2f -c pamu2fcfg -u admin -o pam://neurosis -i pam://neurosis   # key 1, touch
   nix shell nixpkgs#pam_u2f -c pamu2fcfg -n -o pam://neurosis -i pam://neurosis         # key 2, touch
   ```

   Write ONE line under the comment in `modules/system/auth/u2f-keys`: the
   first output (`admin:<KH1>,<PK1>,es256,+presence`) followed directly by
   the second (`:<KH2>,<PK2>,es256,+presence`). If pamu2fcfg finds no
   device as a normal user, run it with sudo.

2. **rssh**: make an `ssh:admin` resident key on the second key
   (`ssh-keygen -t ed25519-sk -O resident -O application=ssh:admin`) and
   add its public key to `adminAuthorizedKeys` in `modules/system/admin.nix`.

### Clients: forwarding the agent

The agent on the client must hold the `ssh:admin` **sk** key; a plain
`ssh-ed25519` key does not count. Load it with `ssh-add -K` (YubiKey
plugged in), or `ssh-add` the handle file `ssh-keygen -K` writes
(`id_ed25519_sk_rk_admin`). Then `ssh -A` or `ForwardAgent yes`.

On the host:

```sh
echo "$SSH_AUTH_SOCK"; ssh-add -L     # must list the sk-…ssh:admin key
sudo -k; sudo -v                      # "Please touch the device." -> touch at the client
```

### Enabling the factor on a host

Prerequisites: both keys registered, agent forwarding checked on the host,
console access to the host known. One host at a time
([cluster.md, Changing a host](cluster.md#changing-a-host)):

1. **Enable it.** On a branch, set `custom.auth.hardwareFactor.enable = true;`
   in `hosts/<host>/configuration.nix`. CI, merge.
2. **Session A: root shell and switch.** Keep this session open until step
   6. Open a root shell **before** switching, while sudo still takes the
   password:
   ```sh
   cd /etc/nixos && git pull
   sudo -i
   nixos-rebuild switch --flake /etc/nixos#<host>   # m2mini: --override-input m2mini-vendorfw path:/boot/vendorfw
   ```
   Then run the etcd health check.
3. **Session B: rssh path.** With the agent forwarded, `sudo -k; sudo -v`
   asks for a touch at the client and no password, and succeeds.
4. **Session C: no agent.** With `ssh -a` and no key plugged into the host,
   `sudo -k; sudo -v` must fail.
5. **Console**, with a key plugged in: login as admin asks for the touch
   and the password and succeeds; without the touch it fails; `sudo -v`
   succeeds with only a touch; on m2mini, `pkexec true` succeeds with only
   a touch.
6. **Finish.** Close session A's root shell.

If step 3 or 5 fails, roll back from session A with
`nixos-rebuild switch --rollback`, or switch a commit with the option off.

### Lockout and recovery

With the factor on, a host needs a key for sudo **and** for console login.

- **One key lost, the other at hand.** Use the other key for sudo. Remove
  the lost key's credential from `u2f-keys` and its public key from
  `modules/system/admin.nix`, and switch every host. Register a
  replacement before relying on a single key.
- **Both keys lost, a pre-factor generation still on the host.** Boot it
  from the boot menu; sudo and the console take the password there. Switch
  a commit with `custom.auth.hardwareFactor.enable = false;`. c4130 keeps
  only the previous generation (its GC step, [c4130.md](hosts/c4130.md)),
  so this route is gone there after the second switch with the factor on.
- **No such generation.** Physical access with rescue media (the NixOS
  installer; on m2mini an Asahi-capable USB installer):
  1. Mount the root filesystem and run `nixos-enter --root /mnt`.
  2. As root, replace the `/etc/pam.d/sudo` symlink with a file holding
     `auth sufficient pam_unix.so likeauth try_first_pass` and
     `auth required pam_deny.so`, plus the account/password/session lines
     of the current file.
  3. Boot, sudo with the password, and switch a commit that disables the
     factor or adds new keys.

  Emergency and rescue targets give no shell, because root is locked.

## Desktop YubiKey

To enable `custom.yubikey.enable` on a desktop:

1. At the machine with the YubiKey:
   `pamu2fcfg -o pam://sortofasian -i pam://sortofasian` (one line,
   `<user>:<keyHandle>,<pubkey>,es256,+presence`).
2. Store it as the sops key `pam-yubikeys` in the host's
   `secrets/<hostname>.yaml`; evaluation fails without it.
3. Set `custom.yubikey.enable = true;` for the host, PR, merge, switch.
