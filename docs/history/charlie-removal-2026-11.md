# Removing charlie from the servers (2026-11)

History: the two-stage procedure that moved the servers' login from
`charlie` to `admin`. The current state is in
[cluster.md, "Accounts on the servers"](../cluster.md#accounts-on-the-servers).

**Status (2026-11-16):** stage 1 is PR #37; stage 2 is merged for every
server (PRs #38 m2mini, #39 r440, #40 c4130: `custom.server.legacyCharlie.enable = false;`
in `hosts/<host>/configuration.nix`).

> **Unverified:** whether each host has switched to its stage-2 commit, and
> whether the "Afterwards" steps below are done (deleting `/home/charlie`,
> the backups in `r440:/var/backups/charlie-home/`, m2mini's
> `/var/lib/secrets/charlie.passwd`, charlie in the tailnet SSH policy).
> Check a host with `getent passwd admin charlie`.

The option is `custom.server.legacyCharlie.enable`
(`modules/server/legacy-charlie.nix`, default `true`). In stage 1 charlie is
declared exactly as on `main` before PR #37 (wheel; on m2mini also uid 1000,
dialout, fish, Nix trust, set in `hosts/m2mini`), with no password option, so
his existing `/etc/shadow` hash stays. The `/etc/nixos` owner follows the
same option (tmpfiles `Z` rule in `modules/server/default.nix`).

## Procedure

Decision (2026-11-13): the servers (c4130, r440, m2mini) end up with one
local login, `admin`; the `charlie` account goes away on them (Famine keeps
charlie). It happens in two stages, each a plain `git pull && nixos-rebuild
switch` of `main`, so no switch both creates admin and removes charlie. The
switch between them is `custom.server.legacyCharlie.enable`
(`modules/server/legacy-charlie.nix`, default `true`). Stage 2 is per host:
one small PR per host sets `custom.server.legacyCharlie.enable = false;` in
that host's `hosts/<host>/configuration.nix` (m2mini, then r440, then
c4130), so each host leaves stage 1 only when its own PR is merged and
switched:

| | Before (main up to PR #36) | Stage 1 (PR #37; option on, the default) | Stage 2 (per-host PR; option off for that host) |
| --- | --- | --- | --- |
| Logins | charlie (wheel) | charlie (wheel, unchanged) and admin (wheel) | admin (wheel) only |
| `users.mutableUsers` | true | true | false |
| charlie's password | his `/etc/shadow` hash (set with `passwd`) | the same, untouched | account removed; `/home/charlie` stays |
| admin's password | – | sops `admin-password`, written to `/etc/shadow` once, when admin is created | sops `admin-password`, rewritten at every activation |
| root | as installed | untouched | locked (`!`) |
| `/etc/nixos` owner | charlie:root | charlie:root (tmpfiles `Z`) | admin:root (tmpfiles `Z`) |
| m2mini extras (dialout, fish, Nix trust) | charlie | charlie and admin | admin |
| c4130 GPU window kills GPU jobs of | charlie | charlie and admin | admin |

**Who runs what.** The user runs every command that needs sudo, in a
terminal on the host (`ssh -t <user>@<host> bash`; on m2mini the login shell
is fish, so start `bash` first). Blocks marked *user* say as which account.
Blocks marked *read-only* need no sudo; a cloud session may run them over
Tailscale SSH (as charlie before stage 1, as admin after), e.g.
`ssh -o ProxyCommand="tailscale --socket=/var/run/tailscale/tailscaled.sock nc %h %p" admin@$H bash -s <<'EOF' … EOF`
(give `</dev/null` to anything in the script that reads stdin).

**Why two stages** (nixpkgs 26.05 `nixos/modules/config/update-users-groups.pl`,
run at every activation):
- An existing `/etc/shadow` line is rewritten only when `mutableUsers` is
  false (`$sp_pwdp = "!" if !$spec->{mutableUsers}`, then the declared hash
  if there is one). With mutable users the line stays as it is.
- An account without a shadow line (a new one) gets its declared hash: the
  content of `hashedPasswordFile`, which is read for every user, else `!`.
- A user listed in `/var/lib/nixos/declarative-users` (written by the
  previous activation) and no longer declared is removed, mutable or not.
- uids: `/var/lib/nixos/uid-map` keeps every user ever created, and a
  re-created user gets its old uid back.

So in stage 1 nothing existing changes: charlie keeps his password and
root stays as it was; admin gets its hash once, at creation. Because the
users are mutable, a later change of `admin-password` does not reach
`/etc/shadow` on a stage-1 server (stage 2 applies it, or `sudo passwd
admin`). In stage 2 every shadow line is rewritten: root `!`, admin from
sops, charlie removed.

**What a rollback does** (`sudo nixos-rebuild switch --rollback`, or an
older generation in the boot menu):

| From | To | Result |
| --- | --- | --- |
| stage 1 | pre-sops generation | admin is removed (its home stays); charlie, his password and root are unchanged. Safe. |
| stage 2 | stage-1 generation | charlie comes back (same uid, home if still there) **without a password** (`!`: Tailscale SSH works, sudo does not); admin keeps its password and sudo. `/etc/nixos` goes back to charlie (as admin: `sudo chown -hR admin:root /etc/nixos` before pulling). Safe. |
| stage 2 | pre-sops generation | admin removed, charlie re-created with `!`, root locked: **nobody can sudo**. This is why stage 1 ends by deleting the pre-sops generations on each host, and why stage 2 checks that none is left. |

**uids and subuids.** admin, created in stage 1 while charlie exists, gets
the lowest free uid ≥ 1000 that is not in the uid-map (1001 or higher,
never charlie's; charlie is 1000 on m2mini, pinned; `id -u charlie`
elsewhere). After stage 2 charlie's uid and subuid range (100000:65536, in
`/var/lib/nixos/auto-subuid-map`) stay reserved; admin has its own
(typically 165536:65536), so charlie's rootless podman storage on r440
(`~/flint-swebench`, `~/.local/share/containers`) is not usable by admin as
is. `/home/charlie` and its files then show charlie's numeric uid as owner;
the home stays mode 0700.

**Order:** m2mini, then r440, then c4130 (GC first, outside 22:00–05:55
EST). One host at a time; finish a host, including the
[etcd health check](../cluster.md#etcd-health-check-any-member-in-bash), before the next.

### Stage 1: admin next to charlie (PR #37)

Preconditions: PR #37 is merged and CI was green (its secrets-guard checks
that every host is a recipient of the sops files it uses); on the host, the
pre-switch check `sopsDecrypt` refuses the switch if the host cannot decrypt
them. No admin account exists yet.

Per host (`H=m2mini`, then `r440`, then `c4130`):

**1. Inventory** (*read-only*, as charlie):

```sh
hostname; id charlie; id admin                 # admin: "no such user" (if it exists, stop and ask)
stat -c '%U:%G %a' /etc/nixos                  # charlie:root 755
git -C /etc/nixos status --short | head        # empty
ls -1d /nix/var/nix/profiles/system-*-link     # the generations, all pre-sops
```

**2. c4130 only: GC** (*user*, as charlie), outside 22:00–05:55 EST:

```sh
sudo nix-env -p /nix/var/nix/profiles/system --delete-generations +2 && sudo nix-collect-garbage
```

**3. Pull and switch** (*user*, as charlie, charlie's sudo password):

```sh
cd /etc/nixos && git pull --ff-only && git log -1 --oneline
sudo nixos-rebuild switch --flake /etc/nixos#$(hostname)
#   m2mini: add  --override-input m2mini-vendorfw path:/boot/vendorfw
echo "switch: $?"; systemctl --failed --no-legend
```

The output shows `sops: decrypts …` for each sops file (pre-switch check)
and no `removing user`, no `ERROR: no password for admin`.

**4. Verify** (*read-only*, as charlie):

```sh
id admin; id charlie                           # both in wheel; m2mini: both in dialout
getent passwd admin charlie | cut -d: -f1,3,7  # m2mini: both …/bin/fish
stat -c '%U:%G' /etc/nixos                     # charlie:root
```

Then the user logs in as admin over Tailscale SSH (from any machine on the
tailnet) and checks sudo:

```sh
ssh -t admin@$H bash          # Tailscale SSH as admin
sudo -v && echo "sudo ok"     # admin's password (sops admin-password)
sudo awk -F: '$1~/^(root|admin|charlie)$/ {print $1, substr($2,1,3)}' /etc/shadow
#   admin $y$   charlie (unchanged, e.g. $y$ or $6$)   root (unchanged)
```

If admin's sudo fails, stay in stage 1 and fix it as charlie: admin's
shadow line was probably written as `!` (the hash file was missing when
admin was created; look for `ERROR: no password for admin` in the switch
output). With mutable users a later switch does not repair it, so set it
once by hand: `sudo passwd admin` (as charlie) and type admin's password
from sops. Then verify again.

**5. etcd health check** (*user*, any account with sudo):
[etcd health check](../cluster.md#etcd-health-check-any-member-in-bash). Plus
`systemctl --failed`.

**6. Delete the pre-sops generations** (*user*, as admin, once 4 and 5
pass). Keep only the current generation and rewrite the boot menu, so
nobody can roll back or boot past stage 1 (see the rollback table):

```sh
sudo nix-env -p /nix/var/nix/profiles/system --delete-generations old
sudo /run/current-system/bin/switch-to-configuration boot   # boot menu: current only; does not activate
sudo nix-collect-garbage                                    # optional; frees the old closures (c4130: do it)
```

Check (*read-only*, as admin); every generation must say `admin=yes`:

```sh
for g in /nix/var/nix/profiles/system-*-link; do
  j=$(grep -o '/nix/store/[a-z0-9]*-users-groups\.json' "$g/activate" | head -1)
  printf '%s admin=%s\n' "${g##*/}" "$(grep -q '"name":"admin"' "$j" && echo yes || echo NO)"
done
```

Until step 6, a rollback to the previous (pre-sops) generation is safe and
only removes admin. After it, fix forward with a PR.

### Stage 2: charlie removed (one PR per host)

Start only when stage 1 is done on all three hosts. Then do the whole of
stage 2 for one host (m2mini, then r440, then c4130), including the etcd
check, before the next host's PR.

Once, for all hosts: the backup check below. Per host, before its PR:
- Stage 1 is done on this host: admin logs in and `sudo -v` works, and
  the generation check above says `admin=yes` for every generation
  (*read-only*, as admin).
- Nothing imperative that stage 2 would delete: immutable users remove
  every account and group that is not declared. *Read-only*, as admin, in
  bash; both lists must be empty (charlie is still declared here):

  ```sh
  comm -23 <(cut -d: -f1 /etc/passwd | sort) <(tr ' ' '\n' < /var/lib/nixos/declarative-users | sort)
  comm -23 <(cut -d: -f1 /etc/group | sort) <(tr ' ' '\n' < /var/lib/nixos/declarative-groups | sort)
  ```

- Backups of `/home/charlie`: done (2026-11-13), `r440:/var/backups/charlie-home/{c4130,r440,m2mini}.tar.zst`
  (root, 0600; directory 0700), all complete. Integrity check still to do
  (*user*, on r440, as admin; reads throttled, r440's root is the HDD that
  also holds etcd's WAL):

  ```sh
  Z=$(nix build --no-link --print-out-paths nixpkgs#zstd)/bin/zstd
  for h in c4130 r440 m2mini; do
    sudo systemd-run --scope -q -p 'IOReadBandwidthMax=/var/backups 60M' \
      "$Z" -tq /var/backups/charlie-home/$h.tar.zst && echo "$h ok" || echo "$h BAD"
  done
  sudo stat -c '%n %y' /var/backups/charlie-home/*.tar.zst    # backup times, for the next check
  ```

  Every archive must say `ok`. Files charlie changed after his backup are
  not in it: on the host, *user*, as admin,
  `sudo find /home/charlie -xdev -newermt '<that host's backup time>' | head`;
  if anything that matters shows up, ask the user (re-take that backup).

Then, on the host, steps 1 to 5:

**1. Stop charlie's login sessions** (*user*, as admin). **Never
`pkill -u charlie`:** uid 1000 is also the uid that container processes run
as (authentik's gunicorn on m2mini, about 8 pod processes on every node,
found 2026-11-13), so that would kill pods. Removing charlie doesn't touch
them: uid 1000 stays reserved in `/var/lib/nixos/uid-map` and those
processes just show as `1000` afterwards. End only charlie's systemd user
slice:

```sh
sudo loginctl terminate-user charlie 2>/dev/null; sleep 3
ps -u charlie -o pid=,cgroup=,comm= | grep 'user-1000\.slice'   # nothing listed (pods are in kubepods, leave them)
```

**2. Copy what is still used to `/home/admin`** (*user*, as admin):

| Host | Copied (to the same path under `/home/admin`) | Left in `/home/charlie` (and the backup) |
| --- | --- | --- |
| c4130 | `archive` (scripts, `nixos-backups`, notes, results), `vllm-hand` (the active hand harness), `.cloudflared` (account cert) | `vllm-sm70-work` (71 GB), `.cache`, `.triton`, `calib-cache`, `.claude`, dotfiles |
| r440 | `archive`, `.kube` (then also the old cluster PKI directory, shredded after PKI phase 2's P9; the original in `/home/charlie` and the backups still hold it, the live `sa.key` included) | `flint-swebench` (68 GB, rootless podman under charlie's subuids), `vllm-sm70-work`, `work`, `prebuild`, `tls`, `.cache`, podman config/storage |
| m2mini | `archive` | `catenix` (a checkout; clone again if needed), `tls`, `.ssh` (admin uses the YubiKey), `.cache` |
| all | `.config/sops` if present (age-plugin-yubikey identity stub, not secret) | |

```sh
sudo bash -s <<'EOF'
set -euo pipefail
g=$(id -gn admin)
# Create every missing directory between /home/admin and $1, owned by admin.
mkdir_admin() {
  local d=$1 todo=()
  while [ "$d" != /home/admin ] && [ ! -e "$d" ]; do todo=("$d" "${todo[@]}"); d=$(dirname "$d"); done
  for d in "${todo[@]}"; do install -d -m 0700 -o admin -g "$g" "$d"; done
}
cp_item() {
  [ -e "/home/charlie/$1" ] || { echo "skip $1 (missing)"; return 0; }
  [ ! -e "/home/admin/$1" ] || { echo "/home/admin/$1 exists, not overwriting" >&2; return 1; }
  mkdir_admin "$(dirname "/home/admin/$1")"
  cp -a "/home/charlie/$1" "/home/admin/$1"
  chown -hR "admin:$g" "/home/admin/$1"
  echo "copied $1"
}
case $(hostname) in
  c4130)  items="archive vllm-hand .cloudflared" ;;
  r440)   items="archive .kube" ;;
  m2mini) items="archive" ;;
esac
for i in $items .config/sops; do cp_item "$i"; done
find /home/admin ! -user admin | head          # nothing listed
# absolute paths into the old home (venv shebangs, configs) to fix by hand:
grep -rIl --exclude-dir=nixos-backups /home/charlie /home/admin 2>/dev/null | head -20 || true
EOF
```

**3. This host's PR**: add `custom.server.legacyCharlie.enable = false;`
to `hosts/<host>/configuration.nix` (only this host; the option's default
stays `true`, so the hosts not yet through stage 2 are unaffected), CI,
merge.

**4. Pull and switch** (*user*, as admin). admin cannot pull a checkout
charlie owns, so re-own it first (the switch's `Z` rule keeps it so):

```sh
sudo chown -hR admin:root /etc/nixos
cd /etc/nixos && git pull --ff-only && git log -1 --oneline
# c4130: GC first (stage 1, step 2), outside 22:00–05:55 EST
sudo nixos-rebuild switch --flake /etc/nixos#$(hostname)
#   m2mini: add  --override-input m2mini-vendorfw path:/boot/vendorfw
echo "switch: $?"; systemctl --failed --no-legend
```

The activation prints `removing user ‘charlie’`. Then the etcd health check.

**5. Verify.** *Read-only*, as admin:

```sh
getent passwd charlie || echo "charlie gone"; id admin
stat -c '%U:%G' /etc/nixos; find /etc/nixos ! -user admin | head    # admin:root, nothing listed
ls -ld ~ ~/archive && ls ~/archive | head
# r440: the moved kubeconfigs
ls -l ~/.kube
# c4130: the account cert (read-only call)
ls -l ~/.cloudflared/cert.pem ~/archive/scripts/verify_vllm.py && cloudflared tunnel list </dev/null | head -3
# m2mini: groups and shell
id; getent passwd admin                      # dialout + wheel; …/bin/fish
```

*User*, as admin:

```sh
sudo -v && echo "sudo ok"
sudo awk -F: '$1~/^(root|admin)$/ {print $1, substr($2,1,3)}' /etc/shadow   # root !, admin $y$
[ "$(hostname)" = m2mini ] && sudo rm -f /var/lib/secrets/charlie.passwd    # unused since stage 1
```

If something is wrong: `sudo nixos-rebuild switch --rollback` returns to
the stage-1 generation (see the rollback table: charlie back without a
password, admin unchanged, `/etc/nixos` back to charlie). Revert this
host's PR too, or the next pull switches it to stage 2 again.

Then the next host, from its preconditions.

### Afterwards (needs the user)

- `/home/charlie` stays as it is until the user OKs deleting it:
  `sudo rm -rf --one-file-system /home/charlie` (on r440 this also frees
  the Nix GC root under `~/flint-swebench/podman-pkg`). Stray files in
  `/tmp` and `/var/tmp` with charlie's uid (`sudo find /tmp /var/tmp -xdev -uid <uid>`) go then too.
- The backups in `r440:/var/backups/charlie-home/` stay until the user OKs
  deleting them (they hold secrets; listed in [secrets.md](../secrets.md)).
- Tailnet SSH policy: drop `charlie` as a login user for the servers
  (admin console); keep it wherever Famine needs it.
