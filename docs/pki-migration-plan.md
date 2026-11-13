# Plan: YubiKey root CA, intermediates, cert-manager (2026-11-13)

Status: **plan, nothing done yet.** Current state is in [pki.md](pki.md).

## Decisions (made 2026-11-13)

- **One trust root for everything**: a new root CA. Its key is generated on
  the YubiKey plugged into c4130, in PIV slot **9c (Digital Signature)**.
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
signs with the key remotely, even as root on c4130. P-384 matches today's
`cluster-ca`.

## Target hierarchy

```
neurosis Root CA 2026  (YubiKey 9c, P-384, 20 y, CA:TRUE pathlen:1)
├── neurosis workload CA   (in cluster: Secret cert-manager/cluster-ca, P-384, 2 y, pathlen:0)
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
A host-tools ──┐
B cluster-pki ─┼──► E rehearsal (soft key) ──► F ceremony on c4130 ──► G workload cutover
C cert-manager ┤                                                   └─► H front-proxy → k8s → etcd rotation
D docs ────────┘
```

| Node | What | Output |
| --- | --- | --- |
| **A** host-tools | `hosts/c4130`: `services.pcscd.enable = true`; add `yubikey-manager`, `yubico-piv-tool` (ykcs11), `step-cli` + `step-kms-plugin`, `openssl` + `pkcs11-provider`. No agenix/mkHost. | PR, then switch c4130 (rules below) |
| **B** cluster-pki | New modes: `--ca-csr <ca>` (generate the intermediate key and CSR in `ca/<ca>/next/`; don't self-sign) and `--ca-import <ca> <cert>` (check that the cert matches the key, `pathlen:0`, and that it chains to `cluster/pki/root-ca.pem`). Wire into `--rotate-ca … --phase begin`. Leaves get chain files. Trust bundles hold the intermediate only, with the anchor check described above. Also fix the `--out` default to XDG and the `.gitignore` patterns (open TODOs). | PR |
| **C** cert-manager | `issuers.nix`: drop the `selfsigned` → `cluster-ca` root Certificate. `cluster-ca` ClusterIssuer reads a Secret created out-of-band (`tls.crt` = intermediate + root, `tls.key`, `ca.crt` = root). Optional: trust-manager `Bundle` that distributes the root to namespaces. Nothing requests from `cluster-ca` today, so the swap has no consumers to break. | PR, merged only after F |
| **D** docs | `pki.md`: rewrite the two-PKI table into one root and two branches. `cluster.md` Secrets table: add rows for the YubiKey PIN, PUK and management key (where they live), the workload intermediate Secret, and the root cert in git (public). | PR |
| **E** rehearsal | Run the full ceremony script against a **software** P-384 key (tmpfs) on r440. Confirm that `step certificate sign --kms` (or the `openssl x509 -req -provider pkcs11` fallback) produces the right extensions, and that etcd, the apiserver and the kubelet accept intermediate-anchored bundles in a kind/test env. | Script known good |
| **F** ceremony | On c4130, **with you physically there** (touch). Steps below. | Root cert, attestation, 4 signed intermediates |
| **G** workload cutover | Create Secret `cert-manager/cluster-ca`, merge C, check that Flux reconciles `cert-manager-issuers`, issue a test Certificate, `openssl verify -CAfile root-ca.pem`. | |
| **H** bootstrap rotation | Existing `--rotate-ca` flow, one CA at a time: front-proxy (lowest risk), then k8s, then etcd (per-node runbook). One host at a time, etcd health check after each. | All bootstrap certs chain to the root |

Rough effort: A–D about 2–3 h of agent time in parallel. E about 1 h.
F about 30 min of your time. G about 20 min. H about 1–2 h spread over
sessions.

## Ceremony (node F)

Preconditions: A is switched on c4130 and E passed. Run it outside the GPU
window if anything requires a switch. Use a tmpfs working dir. Never record
the PIN in shell history or on a command line.

1. `ykman info` → record serial and firmware (need ≥ 5.x for P-384 and
   attestation). `ykman piv info`: slot 9c must be empty.
2. Change the defaults: `ykman piv access change-pin`, `change-puk`, and
   `change-management-key --generate --protect` (the management key is
   stored on the card, PIN-protected). Record where the PIN/PUK live in
   `cluster.md` Secrets.
3. `ykman piv keys generate --algorithm ECCP384 --pin-policy ALWAYS
   --touch-policy ALWAYS 9c root.pub`.
4. `ykman piv keys attest 9c attest-9c.pem` and `ykman piv certificates
   export f9 attest-f9.pem`. These prove the key was generated on-device
   and is non-exportable.
5. Self-sign the root with `CA:TRUE, pathlen:1`, `keyCertSign, cRLSign`,
   20 y, subject `CN=neurosis Root CA 2026,O=neurosis`, via step-kms-plugin
   (`--kms 'yubikey:' --key 'yubikey:slot-id=9c'`). Import it into slot 9c
   (`ykman piv certificates import 9c root.pem`).
6. Sign the four intermediate CSRs (PIN + touch each):
   - workload: key and CSR generated on c4130 in tmpfs;
   - k8s, etcd, front-proxy: CSRs from `cluster-pki --ca-csr` on r440,
     copied over (CSRs are public).
7. Commit `root-ca.pem`, `attest-9c.pem` and `attest-f9.pem` to
   `cluster/pki/` (public). Hand the workload key straight to
   `kubectl create secret tls`, then shred the tmpfs. Copy the three
   bootstrap intermediate certs back to r440 and run `--ca-import`.

## Host change rules (from CLAUDE.md)

- c4130 switch: GC first (`nix-env … --delete-generations +2 &&
  nix-collect-garbage`), outside 22:00–05:55 EST, one host at a time, then
  the etcd health check from `cluster.md`. Builds happen on r440.
- `sudo` needs charlie's password on stdin; SSH only when allowed for the
  task.

## Risks

- **Single non-exportable root (accepted).** Mitigations: bootstrap
  intermediates last 5 y, so losing the root doesn't break anything
  immediately, and there's time to re-root. The serial, attestation and
  root fingerprint go in git. The PUK is stored offline, so a PIN lockout
  isn't fatal. Never run `ykman piv reset` (it wipes 9c).
- **YubiKey left plugged into c4130.** Touch-always blocks remote signing.
  The card can still be pulled, or the PIN brute-forced against its retry
  counter (3 tries, then PUK). Consider storing it unplugged between
  ceremonies.
- **Workload intermediate renewal is manual.** cert-manager will not renew
  a CA Secret it didn't issue. Set a reminder about 60 days before the
  2-year expiry. Leaf durations must stay under the intermediate's
  remaining life.
- **Anchor mistake.** Covered by the anchor check in B and the rehearsal in E.

## Phase 2 prerequisites (not planned yet)

Bootstrap leaves from in-cluster need all of these first:

1. A host-side sync agent that writes certs into `/var/lib/kubernetes/secrets/`
   and reloads the units.
2. Proof that a cold start with every cert expired can be recovered from
   r440 alone (break-glass).
3. A k8s-branch signer that can never sign `system:masters`. Candidates:
   an apiserver CSR API with an approver policy, or a separate intermediate
   whose key is not in etcd.
4. Leaf-expiry monitoring (open TODO).
