# Secrets

Where every secret lives and how to change it. sops files are in git
(`secrets/*.yaml` for the hosts, `k8s/secrets/<namespace>/<name>.sops.yaml`
for the cluster; recipients in `.sops.yaml`); how each is used is in the
code that declares it. Add a row for every new secret. In-cluster sops
Secrets: [k8s/secrets.md](k8s/secrets.md); the PKI: [pki.md](pki.md).

**Editing or re-wrapping a sops file with the YubiKey** is ad hoc: no host
has sops, age-plugin-yubikey or pcscd installed permanently. On any machine
with the YubiKey plugged in, from a checkout of this repo, run
`nix shell nixpkgs#sops nixpkgs#age-plugin-yubikey` and start pcscd for the
session if the machine doesn't already run it. sops finds the YubiKey through
the identity stub in `~/.config/sops/age/keys.txt` (once per user:
`age-plugin-yubikey --identity > ~/.config/sops/age/keys.txt`; the stub is not
secret). Then run `sops …`, enter the PIV PIN and touch the key when it
blinks. On c4130 (no pcscd, no polkit rule for SSH sessions) this needs
root: as admin, `sudo -i`, enter the same `nix shell` (add
`nixpkgs#pcsclite` for `pcscd`), start
`PCSCLITE_HP_DROPDIR=$(nix build --no-link --print-out-paths nixpkgs#ccid)/pcsc/drivers pcscd --foreground --auto-exit &`
and run the identity and `sops` commands as root. pcscd exits by itself once
idle. The offline backup age key works anywhere without any of this
(`SOPS_AGE_KEY_FILE`).

| Secret | Where | How to change |
| --- | --- | --- |
| Host certs and keys (etcd, apiserver, kubelet, admin, …) | `secrets/pki/<node>.yaml` (keys sops-encrypted) | automatic: cert-manager renews, the CronJob `cluster-pki/pki-export` opens a PR; merge and switch ([pki.md](pki.md#where-certs-come-from)) |
| Workload intermediate CA `cert-manager/cluster-ca` | `k8s/secrets/cert-manager/cluster-ca.sops.yaml` | every 2 y, at a ceremony: key made in tmpfs, signed by the YubiKey root, encrypted straight from tmpfs with `sops` into that path, PR, merge, tmpfs shredded |
| Bootstrap intermediate CAs `cluster-pki/{k8s,etcd,front-proxy}-ca` (cluster-admin equivalent) | `k8s/secrets/cluster-pki/*-ca.sops.yaml`; also the only offline copy ([pki.md](pki.md#offline-signing-when-the-cluster-is-down)) | at a ceremony ([pki.md](pki.md#ca-rotation)) |
| Service-account keypair `sa.key` / `sa.pub` | `secrets/cluster-sa.yaml` | a new keypair invalidates every ServiceAccount token |
| `cluster-pki/pki-export-github` (fine-grained token, this repo only, Contents + Pull requests read/write) | `k8s/secrets/cluster-pki/pki-export-github.sops.yaml` | before it expires (≤ 1 y): new token, `sops` the file, PR, merge ([pki.md](pki.md#export-job-github-token)) |
| App Secrets (authentik, Headlamp, Open WebUI, cloudflared tunnel, Flux webhook token, Tranquil PDS, Tangled knot, ATCR, LLDAP) | `k8s/secrets/<namespace>/<name>.sops.yaml` | `sops` the file, PR, merge, restart its readers ([k8s/secrets.md](k8s/secrets.md#changing-a-value-rotation)); for the webhook token also update the GitHub secret `FLUX_WEBHOOK_TOKEN` |
| atcr.io pull credentials `atproto/atcr-io-pull` (an ATProto handle and app password) | `k8s/secrets/atproto/atcr-io-pull.sops.yaml` | new app password on that account, `sops` the file, PR, merge, restart the `atproto` Deployments ([k8s/apps.md](k8s/apps.md#atproto-services)) |
| `flux-system/sops-age` (Flux's age key, recipient `&flux`) | Kubernetes Secret only; never in git, on disk or copied out | once per cluster ([k8s/secrets.md](k8s/secrets.md#the-bootstrap-key-flux-systemsops-age)). Lost: make a new one, set `&flux` to its recipient, `sops updatekeys` every `k8s/secrets/*/*.sops.yaml`, PR, merge |
| `FLUX_WEBHOOK_TOKEN`, `FLUX_WEBHOOK_URL`, `NIX_CACHE_NETRC` | GitHub Actions secrets | by hand ([ci.md](ci.md)) |
| Cloudflare account cert (DNS routes) | `c4130:~admin/.cloudflared/cert.pem` | `cloudflared tunnel login` |
| Binary cache: signing key, htpasswd, client netrc | `secrets/r440.yaml` (`harmonia-signing-key`, `nix-cache-htpasswd`), `secrets/<host>.yaml` (`nix-cache-netrc`) | [build-cache.md](build-cache.md) |
| Remote-build SSH key `nixremote` | `secrets/c4130.yaml`; public half in `hosts/r440/builder.nix` | `ssh-keygen`, `sops` the private half, update the public half, PR, merge, switch both |
| Tailscale auth key (reinstall only) | `/var/lib/tailscale/authkey` (root, 0600) on the new server; delete after enrolment | admin console: pre-approved, non-ephemeral, tagged `tag:node` ([cluster.md](cluster.md#tailscale)) |
| Admin password | `admin-password` (plaintext) in `secrets/common.yaml` | `sops secrets/common.yaml`, switch every host. A host that can't decrypt `common.yaml` has no admin password and root is locked; the pre-switch check `sopsDecrypt` refuses such a switch |
| charlie's password (Famine only) | `charlie-password` in `secrets/famine.yaml` | `sops secrets/famine.yaml` |
| sops-nix host identities | each host's `/etc/ssh/ssh_host_ed25519_key` (never in git); its `ssh-to-age` recipient is an anchor in `.sops.yaml` | a reinstalled host has a new key: update `.sops.yaml` and `sops updatekeys` before its first switch |
| sops admin identities | YubiKey 5 serial 19830800, PIV slot 82 (`admin_yubikey`), carried by the user; offline passphrase-protected backup age key (`admin_backup`). The same YubiKey holds FIDO2 `ssh:admin` and the root CA key in PIV slot 9c ([pki.md](pki.md#yubikey-root-ca)). PINs are held by the user offline | never `ykman piv reset` it. `age-plugin-yubikey --generate`, `age-keygen \| age -p`, `ssh-keygen -t ed25519-sk -O resident` |
| YubiKey PIV PUK | `yubikey-19830800-piv-puk` in `secrets/admin.yaml` (admin keys only) | unblocks the PIV PIN after 3 wrong tries; while the PIN is blocked, read `admin.yaml` with `admin_backup` |
| Desktop YubiKey files | `pam-yubikeys` in `secrets/famine.yaml` | made at Famine with the YubiKey ([hosts/famine.md](hosts/famine.md)) |
| Pestilence Transmission `rpc-password` | **plaintext in git**, `hosts/Pestilence/servarr.nix` | rotate and move to sops before restoring the host |
| `TAIL_AUTH_KEY` | env var of the Claude Code cloud environment (its only secret) | environment settings |

No plaintext secret goes into git, the Nix store or a command line (the
Pestilence `rpc-password` is the one exception); in git secrets exist only
sops-encrypted.
