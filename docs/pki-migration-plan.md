# Plan: YubiKey root CA, intermediates, cert-manager (2026-11-13)

Status (2026-11-13): **A–F done; the ceremony ran on 2026-11-13.** G goes
live when the PR with `k8s/secrets/cert-manager/cluster-ca.sops.yaml`
merges. H is next. Current state is in [pki.md](pki.md); what happened is
in [History](#history).

## Decisions (made 2026-11-13)

- **One trust root for everything**: a new root CA. Its key is generated on
  the **admin YubiKey (serial 19830800)**, in PIV slot **9c (Digital
  Signature)**. That card already holds the sops admin age key (slot 82)
  and the FIDO2 key `ssh:admin`. It travels with the user; the ceremony
  runs on whatever machine the user plugs it into, and nothing about the
  root depends on a particular host (decision 2026-11-13).
- **The workload intermediate key goes in sops**, at
  `k8s/secrets/cert-manager/cluster-ca.sops.yaml` (recipients: admins +
  `&flux`), applied by the Flux Kustomization `secrets` (decision
  2026-11-13).
- **Phased** (option "branches now, all later"):
  - **Phase 1**: the root signs four intermediates. The **workload**
    intermediate lives in the cluster as cert-manager's `cluster-ca`
    ClusterIssuer. The **k8s, etcd and front-proxy** intermediates replace
    today's three self-signed CAs. cluster-pki keeps issuing from them on
    r440.
  - **Phase 2 (later, separate plan)**: bootstrap leaves also come from the
    in-cluster side. This is gated on the prerequisites listed at the end.
- **Root key backup: none.** The key is generated on the device and is not
  exportable. Accepted risk: if the key is lost or the card is reset, every
  intermediate must be re-rooted. Mitigations are in [Risks](#risks).

## Why slot 9c

Yubico's slot page says 9c is "used for digital signatures for the purpose
of document signing, or signing files and executables". Its PIN "must be
submitted every time immediately before a sign operation". It is the only
signature slot, and PIN-always suits a key that signs a few times a year.
The page doesn't mention CAs; the choice of 9c for a CA is our own reading
of it. 9a is meant for authentication and keeps the PIN once entered. 9d is
for encryption, 9e for physical access with no PIN, 82–95 for old
key-management keys, and f9 for attestation.

Key policy: **ECDSA P-384, `--pin-policy ALWAYS --touch-policy ALWAYS`**.
That means one signature per PIN entry plus a physical touch, so nobody
signs with the key remotely, even as root on the host it is plugged into. P-384 matches today's
`cluster-ca`.

## Target hierarchy

```
neurosis Root CA 2026  (YubiKey 9c, P-384, 20 y, CA:TRUE pathlen:1)
├── neurosis workload CA   (in cluster: Secret cert-manager/cluster-ca from sops, P-384, 2 y, pathlen:0)
│     └── workload leaves via ClusterIssuer cluster-ca (unchanged API for users)
├── neurosis k8s CA        (r440 cluster-pki, 5 y, pathlen:0) → apiserver, kubelet, admin, SA-adjacent leaves
├── neurosis etcd CA       (r440 cluster-pki, 5 y, pathlen:0) → etcd server/peer/client
└── neurosis front-proxy CA(r440 cluster-pki, 5 y, pathlen:0) → front-proxy-client
```

The service-account keypair is a bare keypair, not a cert, and is out of
scope.

### The rule that keeps this safe: anchor on the intermediate, never the root

The root signs the workload intermediate, whose key sits in etcd. If any
bootstrap trust file (`ca.pem`, `etcd-ca.pem`, `front-proxy-ca.pem`,
kubelet `clientCAFile`) contained the **root**, someone holding the
workload key could mint a `O=system:masters` client cert, and the apiserver
would accept it. So:

- Bootstrap trust bundles hold **only their own intermediate**. Go's
  `x509.Verify` accepts a non-self-signed cert in the root pool as an
  anchor. etcd, the apiserver and the kubelet are all Go.
- Server leaves ship the full chain (leaf + intermediate) in the cert file,
  so clients that trust only the root (browsers, workloads) can verify them.
- Only workloads, plus the trust-manager bundle if we add one, trust the
  root itself.
- `cluster-pki status` and CI should **fail** if any bootstrap bundle
  contains a self-signed cert or the workload intermediate.

## Work breakdown (DAG)

The nodes run in parallel unless an arrow says otherwise. Code nodes are one
branch, CI run and PR each.

```
A tools (done) ──────┐
B cluster-pki (done) ┼─► E rehearsal (done) ─► F ceremony (done) ─► G workload cutover (at merge)
C cert-manager (done)┤                                          └─► H front-proxy → k8s → etcd (next)
D docs (done) ───────┘
```

| Node | What | Output |
| --- | --- | --- |
| **A** tools | **Done, no host change.** Flake package `ca-ceremony-tools`: `yubikey-manager`, `yubico-piv-tool` (ykcs11), `step-cli` + `step-kms-plugin`, `openssl` + `pkcs11-provider` (wrapper `ca-openssl`; unused, it crashed in E), and `ca-pcscd`, a temporary pcscd for hosts that don't run one. Used through `nix shell <flake>#ca-ceremony-tools`; nothing is installed on any host, so no switch. | Package |
| **B** cluster-pki | **Done.** New modes: `--ca-csr <ca>` (generate the intermediate key and CSR in `ca/<ca>/next/`; don't self-sign) and `--ca-import <ca> <cert>` (check that the cert matches the key, `pathlen:0`, and that it chains to `cluster/pki/root-ca.pem`). Wire into `--rotate-ca … --phase begin`. Leaves get chain files. Trust bundles hold the intermediate only, with the anchor check described above. Also fix the `--out` default to XDG and the `.gitignore` patterns (open TODOs). | PR |
| **C** cert-manager | **Done** (merged in #43; the old Certificate was confirmed gone from the cluster on 2026-11-13, before the ceremony). `issuers.nix`: drop the `selfsigned` → `cluster-ca` root Certificate. `cluster-ca` ClusterIssuer reads the Secret `cert-manager/cluster-ca` (`tls.crt` = intermediate + root, `tls.key`, `ca.crt` = root), which comes from sops (G). Optional: trust-manager `Bundle` that distributes the root to namespaces. Nothing requests from `cluster-ca` today, so the swap has no consumers to break. | Merge before G (see G). Until then the issuer stays Ready on the old self-signed Secret. trust-manager deferred until `cluster/pki/root-ca.pem` exists. |
| **D** docs | **Done.** `pki.md`: one root and two branches, the anchor rule, a YubiKey root CA section. `cluster.md` Secrets table: the root key as a second PIV use on the existing admin YubiKey rows, the workload intermediate as a sops Secret, and the root cert in git (public). | PR |
| **E** rehearsal | **Done (software rehearsal):** the ceremony commands ran against a SoftHSM key through step-kms-plugin. All PASS: Go TLS and etcd 3.7.3 accept a client cert when the trust file holds only the k8s intermediate; they reject a workload-signed `system:masters` cert with that same trust file; they **accept** it if the root is in the trust file (so the anchor rule is needed); a server cert file with leaf + intermediate verifies against the root alone. The openssl/pkcs11 fallback crashed and is dropped. | Ceremony commands and gotchas (F) |
| **F** ceremony | **Done 2026-11-13** ([History](#history)). Ad hoc on whatever machine the user plugs the card into (a desktop like Famine, or a server). **The user runs every step** (PIN, touch, sudo). No host switch. Steps below. | Root cert, attestation, 4 signed intermediates, the sops file for `cluster-ca` |
| **G** workload cutover | **Order matters.** (1) Merge C first. It removes the old self-signed `Certificate cluster-ca`; confirm it is gone from the cluster (`kubectl -n cert-manager get certificate cluster-ca` → NotFound). Otherwise cert-manager re-issues over the new Secret with a self-signed cert. (2) At the ceremony (F step 7), encrypt the intermediate straight from tmpfs with `sops` into `k8s/secrets/cert-manager/cluster-ca.sops.yaml`, then PR and merge. Flux's Kustomization `secrets` replaces the old Secret (server-side apply adopts it; the old Certificate no longer owns it). No `kubectl create`. Then check `flux get kustomizations secrets` and `cert-manager-issuers` are Ready, and that the live Secret's `tls.crt` is the workload intermediate (fingerprint in `cluster/pki/fingerprints.txt`). Issue a test Certificate, `openssl verify -CAfile root-ca.pem`. | |
| **H** bootstrap rotation | **Done 2026-11-13.** front-proxy first, then k8s and etcd together: begin, reissue and finish for each, one node at a time (m2mini → c4130 → r440), etcd health check and `readyz` after every node, a rolling restart of all workloads after begin. Every bundle now holds only its neurosis intermediate, there are 0 old-CA leaves, and `check-anchors` passes. Gotchas: `admin.kubeconfig` is not regenerated by `reissue` (rebuilt by hand from `admin-r440`); the apiserver keeps adding to `extension-apiserver-authentication` and never removes old CAs (delete it once after finish). | All bootstrap certs chain to the root |

Rough effort: A–D about 2–3 h of agent time in parallel. E about 1 h.
F about 30 min of your time. G about 20 min. H about 1–2 h spread over
sessions.

## Ceremony (node F)

Preconditions: A and E are done, C is merged and the old Certificate
is gone (G step 1). **The user runs every step**; a cloud session holds no
PIN and runs no sudo, and only writes the steps out. Never put the PIN in
shell history or on a command line; the only copy on disk is the 0600
pin-source file in tmpfs (below). The ceremony does **not** change the
PIN, PUK or management key (already set for sops), never touches slot 82
(the sops key), and never runs `ykman piv reset`.

0. Plug the card into the machine of your choice and enter
   `nix shell <flake>#ca-ceremony-tools` (includes sops, age-plugin-yubikey
   and yq-go) and run `ca-ceremony` (`MODE=rehearsal` uses SoftHSM, no card).
   A desktop that runs pcscd (Famine) needs nothing else. A server has no
   pcscd: there, follow the ad-hoc procedure for sops on a server
   (docs/cluster.md, "Secrets (all of them)"), i.e. as admin `sudo -i`,
   enter the same `nix shell`; `ca-ceremony` starts `ca-pcscd` itself when no
   pcscd is reachable (it exits when idle).
   Work in a tmpfs directory.
The script is `pkgs/ca-ceremony-tools/ceremony.sh`. It runs these
commands; `<ca>` is `workload`, `k8s`, `etcd` or `front-proxy`:

```sh
ykman --device 19830800 piv keys generate --algorithm ECCP384 \
  --pin-policy ALWAYS --touch-policy ALWAYS 9c root.pub
ykman --device 19830800 piv keys attest 9c attest-9c.pem
ykman --device 19830800 piv certificates export f9 attest-f9.pem
KMS='yubikey:serial=19830800?pin-source=<0600 tmpfs file>'
step certificate create --template root.tpl --not-after 175320h \
  --skip-csr-signature --kms "$KMS" --key 'yubikey:slot-id=9c' \
  "neurosis Root CA 2026" root-ca.pem
step certificate sign --template intermediate.tpl --not-after 43824h \
  --kms "$KMS" <ca>.csr root-ca.pem 'yubikey:slot-id=9c' > <ca>.pem   # workload: 17520h
ykman --device 19830800 piv certificates import --no-update-chuid 9c root-ca.pem
```

1. Check the card first: `ykman --device 19830800 info` (firmware ≥ 5.x
   for P-384 and attestation) and `ykman --device 19830800 piv info`:
   slot 9c must be empty, and slot 82 holds the sops key (leave it).
2. Generate the root key in 9c. The management key is PIN-protected on
   the card, so ykman asks for the PIN.
3. Attest 9c and export the f9 attestation cert. Together they prove the
   key was generated on the card and is not exportable.
4. Self-sign the root: `root.tpl` sets `CN=neurosis Root CA 2026,
   O=neurosis`, `CA:TRUE, pathlen:1`, `keyCertSign, cRLSign` and the AKI;
   20 y (175320h).
5. Sign the four intermediate CSRs with `intermediate.tpl` (`pathlen:0`):
   k8s, etcd and front-proxy 5 y (43824h), workload 2 y (17520h).
   - workload: key and CSR generated in the tmpfs directory;
   - k8s, etcd, front-proxy: CSRs from `cluster-pki --ca-csr` on r440,
     copied over (CSRs are public).
   Then import the root cert into slot 9c.

That is **5 PIN + touch** in all: the root, then one per intermediate.

Gotchas (found in E):

- **The KMS URI must carry `pin-source`.** Without it, step silently tries
  the default PIN 123456 and burns one of the 3 PIN tries. The pin-source
  file is 0600 in the tmpfs directory, written with `read -rs`, and
  shredded with it.
- **The root needs a template.** Without one, step sets neither `O=` nor
  the AKI.
- **`--skip-csr-signature`** saves one touch on the root.
- **step is the only path.** The openssl + pkcs11-provider fallback
  (`ca-openssl`) crashed in E; don't use it.

6. Commit `root-ca.pem`, `attest-9c.pem` and `attest-f9.pem` to
   `cluster/pki/` (public).
7. Workload intermediate into sops, straight from tmpfs, in a checkout on
   a branch: write a `type: kubernetes.io/tls` Secret `cert-manager/cluster-ca`
   with `data` keys sorted (`ca.crt` = root, `tls.crt` = intermediate +
   root, `tls.key`), base64 of the exact bytes, and pipe it into
   `sops encrypt --filename-override k8s/secrets/cert-manager/cluster-ca.sops.yaml`
   (k8s/README.md, "Adding one"). Encrypting needs only the recipients in
   `.sops.yaml`, not the card. Then shred the tmpfs. PR, merge (G).
8. Copy the three bootstrap intermediate certs back to r440 and run
   `--ca-import`.

## Host change rules (from CLAUDE.md)

- No switch is needed for the ceremony (tools come from `nix shell`). Any
  c4130 switch for other work: GC first (`nix-env … --delete-generations
  +2 && nix-collect-garbage`), outside 22:00–05:55 EST, one host at a
  time, then the etcd health check from `cluster.md`. Builds happen on
  r440.
- The user runs every `sudo`; a cloud session writes copy-paste blocks and
  SSHes only when allowed for the task.

## Risks

- **Single non-exportable root (accepted).** Mitigations: bootstrap
  intermediates last 5 y, so losing the root doesn't break anything
  immediately, and there's time to re-root. The serial, attestation and
  root fingerprint go in git. Never run `ykman piv reset` (it wipes 9c and
  the sops key in 82).
- **One card holds the sops admin identity and the root.** Losing or
  resetting it costs both. Mitigations: sops has `admin_backup`, a
  recipient of every file, so no secret is lost. The PUK is in sops
  (`secrets/admin.yaml`), so a PIN lockout isn't fatal; while the PIN is
  blocked the card can't decrypt, so read the PUK with `admin_backup`.
  Touch-always on 9c blocks remote signing whenever the card is plugged in.
- **Workload intermediate in sops.** Anyone with an admin sops identity or
  Flux's age key (`flux-system/sops-age`) can read its key, the same reach
  as the Secret in etcd. It signs nothing the bootstrap side trusts (anchor
  rule), so a leak compromises workload TLS only.
- **Workload intermediate renewal is manual.** cert-manager will not renew
  a CA Secret it didn't issue. It expires 2028-11-12: set a reminder for
  about 2028-09-13 (60 days before); renew by signing a new one and replacing the sops file.
  Leaf durations must stay under the intermediate's remaining life.
- **Anchor mistake.** Covered by the anchor check in B. E showed it is real: etcd accepts a workload-signed `system:masters` cert once the root is in the trust file.
- **Wasted PIN tries.** A KMS URI without `pin-source` burns a try on 123456 (F, gotchas). The PUK in sops covers a lockout.

## History

**2026-11-13: ceremony (F).** Outputs, all public, in `cluster/pki/`:

| Cert | Valid | Notes |
| --- | --- | --- |
| `root-ca.pem` (`CN=neurosis Root CA 2026, O=neurosis`, P-384) | 2026-11-13 to 2046-11-13 | key in YubiKey 19830800 slot 9c, PIN + touch always, cert also in 9c. SHA-256 `03:9D:49:10:E9:7B:6D:39:1E:3A:5E:D5:42:8D:D5:9A:D6:E5:EC:4E:E8:DB:98:2D:FC:51:06:FA:0D:4F:F7:7A`. Attested: `attest-9c.pem` chains to `attest-f9.pem` |
| `k8s-ca.pem`, `etcd-ca.pem`, `front-proxy-ca.pem` | 5 y (to 2031-11-13) | imported on r440 into `ca/<ca>/next/`; not rotated in yet (H) |
| `workload-ca.pem` | 2 y (to 2028-11-12) | key in `k8s/secrets/cert-manager/cluster-ca.sops.yaml` (G) |

Fingerprints of all five: `cluster/pki/fingerprints.txt`.

Gotchas, both fixed in the same PR:

- `ceremony.sh` did not start pcscd, because `ykman list` sees the key over
  FIDO even with no pcscd running.
- `cluster-pki check-anchors` failed falsely in the imported-but-not-begun
  state (fix by Barbara).

**Incident (resolved 2026-11-13): the PIV PIN was exposed** in a
cloud-session transcript during the ceremony. The user rotated it the same
day with `ykman piv access change-pin` (only the PIN changes; the keys in
slots 9c and 82 are unaffected), and the plaintext PIN and sudo-password
files on c4130 were deleted.

## Phase 2: host certs from in-cluster issuers, delivered by sops (planned 2026-11-13)

Status: **P1–P5 built in PR #45; P6–P9 pending.** Phase 1 is complete: the root, all four
intermediates and the rotations of the front-proxy, k8s and etcd CAs (H) were
done on 2026-11-13.

### Decisions

- **The three bootstrap intermediates become cert-manager `Issuer`s**
  (namespaced, not `ClusterIssuer`). They live in a dedicated namespace,
  `cluster-pki`. Only a Certificate created *in that namespace* can use them,
  so the RBAC surface is "who can create Certificates in `cluster-pki`", not
  "anyone with Certificates anywhere". The workload `cluster-ca` stays a
  ClusterIssuer.
- **cert-manager issues every host leaf** that cluster-pki issues today, with
  the same subjects, SANs, usages, key type (RSA 2048) and 1-year lifetime,
  and with `renewBefore: 720h`.
- **An export CronJob moves the leaves into git as sops files and opens a
  PR.** It never decrypts anything (see the sops constraint below). Merging
  stays a human step, which keeps the rule branch → CI → merge → `git pull
  && switch`.
- **Hosts read the certs from sops-nix.** `clusterNode.secretsDir` (already
  an option in `modules/cluster`) points at the sops-nix output directory, so
  the units' cert paths keep their file names. `restartUnits` restarts the
  units that read a renewed cert.
- **Hosts never need the cluster to boot.** The certs are files on disk.
  The cluster is needed only to *renew* them.

### The sops constraint that shapes the export job

sops encrypts each file under one data key. Changing a file means
decrypting that data key, which needs a recipient's private key. So the job
**cannot edit** `secrets/<host>.yaml`. Instead it **regenerates whole new
files** with only the public recipients from `.sops.yaml`:

- `secrets/pki/<host>.yaml`, one per host, with the recipients
  `admin_yubikey`, `admin_backup` and that host (a new `creation_rules` entry
  per host, like the existing ones).
- `encrypted_regex: -key\.pem$`, so only the private keys are encrypted. The certs
  stay plaintext in git: they're public, and PR diffs show exactly what
  changed.

**Checks live in the export job, not in CI** (decision 2026-11-13).
`pki-export.sh` validates every node before it pushes: all of the node's
stems are present (otherwise the node is skipped), each cert chains to
exactly its own intermediate (not the root, not the workload CA), each cert
belongs to that node, each key is encrypted, and each key matches its cert.
It also fails the CronJob if any cert on `main` expires within 14 days. CI
keeps only the secrets guard rule: in `secrets/pki/`, plaintext is allowed
only for values that are pure `CERTIFICATE` blocks, and every `-key.pem`
value must be `ENC[`.

### Safety rules

1. **The anchor rule still holds.** Host bundles (`ca.pem`, `etcd-ca.pem`,
   `front-proxy-ca.pem`) hold only their own intermediate, never the root.
   The bundles are public: they come from `cluster/pki/*-ca.pem` in git,
   not from the cluster.
2. **approver-policy** (cert-manager's `CertificateRequestPolicy`) limits
   each leaf to an exact allow-list: **one policy per leaf** (39), because a
   policy allows a CN and a set of O values independently and so can't tie
   an O to a CN. `k8s-ca` may issue `O=system:masters` only
   for `CN=cluster-admin`, `system:node:<n>` only for the three node names,
   and only the known component CNs. `etcd-ca` may issue only
   `etcd-{server,peer,client-apiserver}-<n>` with their SANs. `front-proxy-ca`
   may issue only `front-proxy-client`. Everything else is denied. The
   namespaced Issuer limits *who* can request a cert; the policy limits
   *what* they get. Known limit: approver-policy accepts a request with
   fewer SANs than the policy allows, never more.
3. **The CA keys enter the cluster through sops.** They go in
   `k8s/secrets/cluster-pki/{k8s,etcd,front-proxy}-ca.sops.yaml` (admins +
   `&flux`), applied by the Flux Kustomization `secrets`. That file is also
   the **break-glass backup**: an admin key can decrypt it on r440 and sign
   leaves offline (`cluster-pki` or `step`) while the cluster is down. After
   the cutover, the plaintext copies in `r440:~admin/.local/share/cluster-pki`
   are retired.
4. **etcd snapshots now contain the bootstrap CA keys.** Treat every snapshot
   (`/var/lib/etcd-snap-*.db`) as cluster-admin material.
5. **The export job reads only the leaves.** Its Role is `get` on the 39
   leaf Secrets by name (no `list`), so it can't read the CA keys.
6. **The export job's GitHub credential** is a GitHub App installation token,
   or a fine-grained token limited to this repo with contents and pull-request
   write access. It's stored as a sops k8s Secret. The job only pushes
   branches named `pki-renew/*`, and it never pushes to `main`.

### Work breakdown (DAG)

```
P1 issuers+policy ──┐
P2 export job ──────┼──► P6 keys into cluster ──► P7 dry run ──► P8 cutover m2mini → c4130 → r440 ──► P9 retire
P3 NixOS sops wiring┤      (user, sops on r440)    (PR, no switch)    (one host at a time)
P4 .sops.yaml, guard┤
P5 cert diff tool ──┘
```

| Node | What | Output |
| --- | --- | --- |
| **P1–P5** | **Done in PR #45.** P1: namespace `cluster-pki`, three CA `Issuer`s, approver-policy with one `CertificateRequestPolicy` per leaf, one `Certificate` per leaf from `cluster/definition.nix`. P2: `pki-export` image and daily CronJob (`get` on the 39 leaf Secrets only); validates each node, then pushes `pki-renew/<date>` and opens a PR when fingerprints differ from `main`. P3: per-node `certSource = "files" \| "sops"`, sops-nix paths under `/run/secrets/pki/` with `restartUnits`. P4: `.sops.yaml` rules for `secrets/pki/<host>.yaml` (`encrypted_regex: -key\.pem$`) and `k8s/secrets/cluster-pki/`, plus the secrets guard rule for `secrets/pki/`. P5: `pki-diff`, which compares cert-manager's leaves with cluster-pki's. | PR #45 |
| **P6** keys into the cluster | **You**, on r440 with the YubiKey: sops-encrypt the three intermediate keys + certs into `k8s/secrets/cluster-pki/*.sops.yaml` straight from the PKI directory (no plaintext copy). PR, merge. Flux creates the Secrets and the Issuers go Ready. | PR |
| **P7** dry run | cert-manager issues all leaves, and the export job opens its first PR. Run the diff tool against cluster-pki's current leaves: everything must match except serials and validity. Merge it. No host switches yet (`certSource` is still `"files"`). | Certs in git |
| **P8** cutover | One host at a time (m2mini → c4130 → r440): set `certSource = "sops"`, PR, merge, `git pull && switch`, etcd health check, `readyz`. It's a **leaf swap under the same intermediates**, so no trust change and no bundle change: lower risk than phase 1's rotations. Roll back by switching the host back to `"files"` (the old files stay in `/var/lib/kubernetes/secrets/` until P9). | All hosts on sops |
| **P9** retire | Remove `certSource = "files"` and `cluster-pki deploy`. Shred the leaves in `/var/lib/kubernetes/secrets/`. Move the r440 PKI directory to an offline archive (the keys are in sops now). Update `docs/pki.md` and the Secrets table in `docs/cluster.md`. | PR |

P6–P8 need you: one sops step and three host switches, about 1 h in
total.

### Renewal, once live

cert-manager renews 30 days before expiry. The export job opens a PR within
a day. You merge it and run `git pull && switch` on each host (restartUnits
restarts only what changed). If a renewal PR sits unmerged, the CronJob
starts failing once a cert on `main` is within 14 days of expiry: a failed
`pki-export` run is the signal. Leaf-expiry monitoring beyond that is a
separate open TODO.

### Open questions

- Should the kubelet client cert use the kubelet's own rotation (CSR API)
  instead? No: that needs the k8s CA key on every control-plane node in the
  controller-manager. Keep one path.
- When does the workload `cluster-ca` (expires 2028-11-12) get renewed? It
  stays a root signature at a ceremony (`docs/pki-migration-plan.md`, step
  F); phase 2 doesn't change that.
