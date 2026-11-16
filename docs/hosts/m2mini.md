# m2mini

Apple Mac mini (M2, 2023; `apple,j473` / t8112), aarch64 Asahi Linux with
16 KiB pages, NixOS 26.05. Config: `hosts/m2mini/`. One of the three cluster
nodes (etcd member `m2mini`, peer `https://m2mini:2380`; control plane;
arm64 worker; keepalived priority 50; authentik's PostgreSQL lives here; see
[cluster.md](../cluster.md)).

| | |
| --- | --- |
| LAN | `end0`, 10.0.0.147 (`cluster/definition.nix`) |
| Tailnet | 100.71.194.116; advertises exit node + 10.0.0.0/16 ([cluster.md, Tailscale](../cluster.md#tailscale)) |
| Disk | NVMe: `/` label `nixos` (ext4), `/boot` label `BOOT` (499 MB vfat ESP) |
| Login shell | **fish** for admin ([Shell](#shell-and-accounts)) |
| Logins | `admin` only once stage 2 is switched ([auth.md](../auth.md)) |

## Files

| File | What |
| --- | --- |
| `default.nix` | imports only |
| `configuration.nix` | Asahi (`hardware.asahi`), hostname, ssh, Tailscale routes, accounts |
| `firmware.nix` | Apple peripheral firmware ([Vendor firmware](#vendor-firmware)) |
| `vendorfw/` | firmware-free placeholder for the `m2mini-vendorfw` input |
| `boot.nix` | filesystems, GRUB, at most 5 generations ([Boot](#boot)) |
| `nix.nix` | Nix settings, trusted users, binary cache |
| `shell.nix` | fish, starship, eza/bat aliases |
| `xdg.nix` | XDG base directories for every login ([XDG](#xdg-directories)) |
| `neovim/` | system-wide Neovim ([Neovim](#neovim)) |

## How it is built

`parts/hosts.nix` builds m2mini with `lib.system.aarch64-linux.mkServer`
(`lib/system/mkServer.nix`: host dir + `modules/cluster` +
`modules/server`); it must not go through `mkHost`, which imports every
`modules/**` file (desktop, home-manager):

```nix
lib.system.aarch64-linux.mkServer {
  path = ../hosts/m2mini;
  nixpkgs = inputs.nixpkgs;
  preModules = [ inputs.apple-silicon-m2mini.nixosModules.default ];
  modules = [ { m2mini.vendorFirmware = inputs.m2mini-vendorfw; } ];
}
```

Flake inputs it uses (`flake.nix`):

| Input | Source | Notes |
| --- | --- | --- |
| `nixpkgs` | `github:NixOS/nixpkgs/nixos-26.05` | shared with c4130 and r440, rev pinned in `flake.lock` |
| `apple-silicon-m2mini` | `github:nix-community/nixos-apple-silicon` @ `57a14ae9` | `nixpkgs` follows `nixpkgs`; the flake's only Asahi input. Pinned to m2mini's old lock rev; bump deliberately |
| `m2mini-vendorfw` | `path:./hosts/m2mini/vendorfw`, `flake = false` | placeholder, overridden on the host ([below](#vendor-firmware)) |

## Deploy

As in [cluster.md, Changing a host](../cluster.md#changing-a-host), plus the
firmware override:

```sh
cd /etc/nixos && git pull
sudo nixos-rebuild switch --flake /etc/nixos#m2mini \
  --override-input m2mini-vendorfw path:/boot/vendorfw
```

`--override-input` implies `--no-write-lock-file`. Without the override the
switch still works but drops the peripheral firmware (Wi-Fi, Bluetooth, …).

## Vendor firmware

Apple's peripheral firmware (Wi-Fi, Bluetooth, webcam, …) is proprietary and
non-redistributable, so it is never committed. The Asahi installer put it on
the ESP as `/boot/vendorfw/firmware.cpio`. The current apple-silicon module
needs `firmware.cpio`; an older raw `all_firmware.tar.gz` cannot stand in.

`firmware.nix` defines `m2mini.vendorFirmware` (a path or null). The flake
passes the `m2mini-vendorfw` input, whose default is the placeholder
`hosts/m2mini/vendorfw/` (no `firmware.cpio`). On the host, the override
above points it at `/boot/vendorfw`; that yields the same store path
(`<nar-hash>-source`) as the old standalone flake's `vendorfw` input, so the
toplevel is unchanged. Without the override (CI, other machines) there is no
`firmware.cpio`, `hardware.asahi.extractPeripheralFirmware` is off, and the
configuration still evaluates and builds, just without the blobs
([ci.md](../ci.md)). `peripheralFirmwareDirectory` is always set, because
the module's default probes `/boot/vendorfw`, which pure evaluation forbids.

Never copy `firmware.cpio`, `firmware.tar` or `manifest.txt` into
`hosts/m2mini/vendorfw/`.

> **Open decision:** `flake.nix` says "Drop this input if Gus stops using
> it" (`TODO(Gus/m2mini)`). Whether that still applies is not in the repo.

## Boot

GRUB with a 1 s timeout; `/boot` is a 499 MB vfat partition, and GRUB copies
each generation's Asahi kernel and initrd there (`/boot/kernels`), so
unbounded generations fill it and a switch fails (77% used with 9
generations on 2026-11-12). `boot.loader.grub.configurationLimit = 5` caps
the menu entries (and the kernels kept on `/boot`); the `nix-gc` pre-start
deletes system profile generations beyond the newest 5 before the daily GC,
so their closures are collected too. journald is capped at 500 MB.

## Shell and accounts

The login shell of admin (and of charlie while `legacyCharlie` is on) is
**fish** (with babelfish, starship and any-nix-shell). Tailscale SSH runs
remote commands through it, so sh syntax needs bash explicitly:

```sh
ssh … admin@m2mini bash -s <<'EOF'
…
EOF
ssh -t … admin@m2mini bash      # interactive
```

`ls` is eza, `cat` is bat, and `flake` opens `/etc/nixos` in nvim.

Accounts: `custom.server.legacyCharlie.enable = false` (stage 2) is set in
`configuration.nix`, so `admin` is the only login. What m2mini adds on top of
[auth.md](../auth.md):

- admin is in `dialout` (serial adapters), uses fish, and is a Nix
  `trusted-users`/`allowed-users` entry (`nix.nix`).
- While `legacyCharlie` is on (stage 1), charlie keeps exactly what he had
  before the sops switch: uid 1000 (pinned), group users, wheel (from
  `modules/server/legacy-charlie.nix`), dialout, fish, Nix trust. His old
  `hashedPasswordFile` is not carried over: with mutable users it applied
  only when charlie was created, so his `/etc/shadow` entry was unchanged.
- After stage 2 charlie's uid 1000 stays reserved in `/var/lib/nixos/uid-map`;
  admin keeps its own uid. The old hash file `/var/lib/secrets/charlie.passwd`
  is unused and is deleted in stage 2
  ([history/charlie-removal-2026-11.md](../history/charlie-removal-2026-11.md)).
- Never put a plaintext password (the `password` option) in the config, in any form.

> **Unverified:** whether m2mini has switched to its stage-2 generation, and
> whether `/var/lib/secrets/charlie.passwd` was deleted, is host state
> (`getent passwd admin charlie`; `ls /var/lib/secrets`).

## XDG directories

`xdg.nix` sets the XDG base directories, and the dotfiles that can follow
them (`HISTFILE`, `INPUTRC`, `LESSHISTFILE`, `WGETRC`), for every login
shell, relative to `$HOME`, which `/etc/set-environment` expands per user
(bash and, through babelfish, fish). admin and `sudo -i` root each get their
own. `XDG_RUNTIME_DIR` is left to pam_systemd (`/run/user/<uid>`). Until
2026-11 these were charlie's absolute paths, forced on every user, and
`XDG_RUNTIME_DIR` was pinned to charlie's uid.

bash and less do not create the parent directories of `HISTFILE` and
`LESSHISTFILE` (history is then silently lost), so tmpfiles creates them
(mode 0700) for admin, root and, while `legacyCharlie` is on, charlie. Each
level is listed, because tmpfiles would otherwise create missing parents as
root. `INPUTRC` and `WGETRC` are only read; a missing file is fine.

## Neovim

`neovim/` builds a system-wide `nvim` (and `EDITOR=nvim` at priority 900).
Every `.lua` and `.vim` file under `neovim/config/` is concatenated into
`customRC` (Lua inside `lua << EOF` blocks). Plugins come from nixpkgs
(telescope, treesitter with all grammars, lualine, gitsigns, nvim-cmp, …)
plus `customPlugins.nix` (deadcolumn.nvim). The wrapper adds `fd`, `ripgrep`
and `git` to nvim's `PATH`.

> **Unverified:** the deadcolumn hash in `neovim/customPlugins.nix` ends in
> `=e` after the base64 padding, which does not look like a valid SRI hash.
> Check whether m2mini's toplevel actually builds it.

## Binary cache

m2mini substitutes from r440's cache (`custom.nixCache.enable`, netrc from
sops `nix-cache-netrc` in `secrets/m2mini.yaml`; without it Nix warns and
uses cache.nixos.org alone). r440 builds and holds x86_64 only, so m2mini
gets only arch-independent paths (sources, fixed-output downloads, data)
from it ([build-cache.md](../build-cache.md)).

## History

Ported in 2026-10 from m2mini's standalone flake (`/etc/nixos`: `flake.nix`,
`m2mini.nix`, `mod/{neovim,boot,nix,shell,xdg}`;
[history/cluster-handoff-2026-10.md](../history/cluster-handoff-2026-10.md)).
Not ported:

- `mod/k8s.nix` (etcd with certs as Nix paths, cri-o, ports 2379/2380 open on
  every interface): the shared cluster module (`modules/cluster` +
  `cluster/definition.nix`) replaces it. It stayed out of tree; the one-time
  parity proof of the port imported it from `/etc/nixos`.
- `mod/tls/`: private keys, never in git or the store.
- the plaintext user password.
