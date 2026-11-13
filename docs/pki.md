# Cluster PKI

The cluster (etcd + Kubernetes on c4130, r440 and m2mini) uses three private
CAs, a service-account keypair and one set of leaf certificates per node. All
of it is generated on the **operator machine** by `cluster-pki` from
`cluster/definition.nix` and copied to the nodes by `cluster-pki-deploy`.
Nothing secret is ever a Nix path, in git, or in `/nix/store`: NixOS modules
reference string paths under `/var/lib/kubernetes/secrets/`. The inventory of
every secret (PKI and the rest) is `docs/cluster.md`, "Secrets (all of them)".
The target design puts those CAs under one YubiKey root; it is not live yet
(see the next section and the [migration plan](pki-migration-plan.md)).

```sh
nix run .#cluster-pki                  # create/refresh everything in ~/.local/share/cluster-pki/<cluster>
nix run .#cluster-pki -- status        # what is issued, by which CA, until when
nix run .#cluster-pki-deploy -- m2mini # stage m2mini's files, print sudo cmds
```

- [Bootstrap PKI and workload PKI](#bootstrap-pki-and-workload-pki)
- [YubiKey root CA](#yubikey-root-ca)
- [Inventory of the legacy PKI](#inventory-of-the-legacy-pki-2026-10-31)
- [New layout](#new-layout)
- [cluster-pki usage](#cluster-pki-usage)
- [Cut-over from the legacy PKI](#cut-over-from-the-legacy-pki)
- [etcd CA rotation runbook](#etcd-ca-rotation-runbook-no-quorum-loss)
- [Phase 2 operations](#phase-2-operations)

## Bootstrap PKI and workload PKI

**Status (2026-11-13):** the root and all four intermediates exist (the
ceremony; [migration plan](pki-migration-plan.md#history)). The workload
intermediate is live once the PR with its sops file merges. The bootstrap
intermediates are imported on r440 but **not rotated in yet**: the
bootstrap PKI still runs on the self-signed "solaris" CAs until each
`--rotate-ca <ca>` (front-proxy, then k8s, then etcd; plan, node H).

There is one root CA with two branches. The branches never share an
intermediate.

```
neurosis Root CA 2026          admin YubiKey (19830800) slot 9c, P-384, 20 y, pathlen:1
├── workload branch (in the cluster)
│   └── neurosis workload CA       Secret cert-manager/cluster-ca (sops), P-384, 2 y, pathlen:0
│         └── workload leaves      ClusterIssuer cluster-ca
└── bootstrap branch (cluster-pki on r440)
    ├── neurosis k8s CA            5 y, pathlen:0 → apiserver, kubelet, admin, ...
    ├── neurosis etcd CA           5 y, pathlen:0 → etcd server/peer/client
    └── neurosis front-proxy CA    5 y, pathlen:0 → front-proxy-client
```

| | Bootstrap branch | Workload branch |
| --- | --- | --- |
| For | etcd, kube-apiserver, controller-manager, scheduler, kubelet, kube-proxy, flannel client, front-proxy, service-account keys, admin kubeconfig | TLS for workloads in the cluster |
| Made by | `cluster-pki` on r440 (this document) | cert-manager in the cluster (`k8s/components/infra/cert-manager/`, [k8s/README.md](../k8s/README.md#cert-manager)) |
| CAs | k8s, etcd, front-proxy intermediates signed by the root (5 y), imported into `ca/<ca>/next/`; keys only in `r440:~admin/.local/share/cluster-pki/neurosis`. Until each is rotated in, the signer is still its self-signed "solaris" CA | `cluster-ca`, the workload intermediate signed by the root (2 y, to 2028-11-12). Its key is sops-encrypted in git (`k8s/secrets/cert-manager/cluster-ca.sops.yaml`); the Flux Kustomization `secrets` applies the Secret, replacing cert-manager's old self-signed one |
| Trusts | its own intermediate only ([anchor rule](#the-anchor-rule)) | the root |
| Delivered as | files in `/var/lib/kubernetes/secrets/` (`cluster-pki-deploy`) | Secrets, issued on request (`issuerRef: {kind: ClusterIssuer, name: cluster-ca}`) |

The service-account keypair is a bare keypair, not a certificate. It is
outside the hierarchy.

**Why the bootstrap PKI stays files.** cert-manager is a set of pods. Pods
need a kubelet registered with an apiserver, that apiserver needs etcd and
its serving cert, the kubelet needs its client cert, and the pod network
(flannel) needs its own. Every one of those certificates must exist before
cert-manager can run, so cert-manager cannot be where they come from. And if
it issued their renewals later, an outage of cert-manager (or of etcd, where
its state lives) at renewal time could leave the control plane unable to
start, with nothing left to fix it from. So they stay files signed offline,
renewed by `cluster-pki` and installed by the operator. Moving bootstrap
leaves into the cluster is a later phase with its own prerequisites (plan,
"Phase 2 prerequisites"); it is not planned yet.

**Why the workload branch has its own intermediate.** The bootstrap CA keys
never leave r440 (CLAUDE.md). A cert-manager `CA` issuer needs its key in a
Secret, i.e. in etcd on all three nodes, readable by anyone with Secret
access in `cert-manager` (and, once it is in sops, by anyone holding Flux's
age key or an admin sops identity). The k8s CA in particular signs `system:masters`
and `system:node:*` client certs, so its key in the cluster would hand out
cluster-admin. The workload intermediate signs nothing the apiserver or
etcd trust, so a leak of it compromises workload TLS only. That holds only
because of the anchor rule.

**Workload intermediate renewal is manual.** cert-manager does not renew a
CA Secret it did not issue. It expires 2028-11-12; about 60 days before
(around 2028-09-13), sign a new one with the root and replace the sops file (PR, merge;
Flux applies it). Leaf durations must stay under its remaining life.

### The anchor rule

Bootstrap trust bundles contain **only their own intermediate**. Never the
root, and never the workload intermediate. This covers `ca.pem`,
`etcd-ca.pem`, `front-proxy-ca.pem` and the kubelet `clientCAFile`.

Why: the root also signs the workload intermediate, whose key sits in etcd.
If `ca.pem` held the root, anyone holding the workload key could mint an
`O=system:masters` client cert that chains to the root, and the apiserver
would accept it as cluster-admin. With only the k8s intermediate as the
anchor, that chain does not verify.

- It works because Go's `x509.Verify` accepts a non-self-signed cert in the
  root pool as a trust anchor. The rehearsal (plan, node E) confirmed both
  halves with etcd 3.7.3: a workload-signed `system:masters` cert is
  rejected with only the k8s intermediate in the trust file, and accepted
  once the root is in it. etcd, the apiserver and the kubelet are all
  Go. The legacy PKI already relied on this: its "temp root" was never on a
  node (see the inventory below).
- Server leaves ship the full chain (leaf + intermediate) in the cert file,
  so clients that trust only the root (browsers, workloads) can verify them.
- Only workloads trust the root itself, plus a trust-manager bundle if one
  is added.
- `cluster-pki check-anchors` (also run by `status`) fails if a bootstrap
  bundle holds the root, a self-signed cert where the CA is an
  intermediate, or another branch's CA ([below](#check-anchors)).

## YubiKey root CA

Made at the ceremony on 2026-11-13 (node F of the
[migration plan](pki-migration-plan.md#ceremony-node-f); outputs in its
[History](pki-migration-plan.md#history)). Valid 2026-11-13 to 2046-11-13,
SHA-256 `03:9D:49:10:E9:7B:6D:39:1E:3A:5E:D5:42:8D:D5:9A:D6:E5:EC:4E:E8:DB:98:2D:FC:51:06:FA:0D:4F:F7:7A`.

The root key is on the **admin YubiKey** (YubiKey 5, serial 19830800),
the card that already holds the sops admin age key in PIV slot 82 and the
FIDO2 key `ssh:admin` ([cluster.md, Secrets](cluster.md#secrets-all-of-them),
[auth.md](auth.md)). The root is a second PIV use on that card.

| | |
| --- | --- |
| Card | admin YubiKey, serial 19830800. It travels with the user and is never parked in a host |
| Slot | PIV **9c** (Digital Signature): the only signature slot, and its PIN is required before every signature. Why not 9a/9d/9e: plan, "Why slot 9c". Slot 82 (sops) is never touched |
| Key | ECDSA P-384, generated on the card, not exportable |
| Policies | `--pin-policy ALWAYS --touch-policy ALWAYS`: one signature per PIN entry plus a physical touch. Nobody signs without the user, not even root on the host it is plugged into |
| Root cert | `CN=neurosis Root CA 2026, O=neurosis`, 20 y, `CA:TRUE, pathlen:1`, `keyCertSign, cRLSign`. Also imported into slot 9c |
| Signs | the four intermediates only: workload (every 2 y), k8s, etcd, front-proxy (every 5 y, or on rotation) |
| In git (public) | `cluster/pki/`: the root cert (`root-ca.pem`, which `cluster-pki --ca-import` checks against), the slot attestation `attest-9c.pem` (it chains to the card's attestation cert `attest-f9.pem`: the key was generated on the card and cannot be exported), the four intermediate certs `{k8s,etcd,front-proxy,workload}-ca.pem` and `fingerprints.txt` |
| Where it runs | ad hoc, on whatever machine the user plugs the card into; nothing about the root depends on a particular host. Tools: `nix shell <flake>#ca-ceremony-tools`. A desktop that runs pcscd (Famine) needs nothing else; on a server, use the ad-hoc procedure for sops on a server (`sudo -i`, then `ca-pcscd &` for a temporary pcscd; [cluster.md, Secrets](cluster.md#secrets-all-of-them)). The user runs every step; a cloud session holds no PIN and runs no sudo |

Rules:

- **Never run `ykman piv reset`.** It wipes every PIV slot: the root key in
  9c and the sops key in 82. The root key has no copy.
- **PIN, PUK and management key** are shared with the sops key; the
  ceremony did not change them. The PIN was exposed during the ceremony
  and rotated the same day (plan, [History](pki-migration-plan.md#history)). The PIN is held by the user, offline. The
  PUK is in sops (`secrets/admin.yaml`). The management key is random and
  PIN-protected on the card, so `ykman` asks for the PIN when it writes
  slot 9c. Never put the PIN on a command line or in shell history. The
  ceremony's only copy is a 0600 `pin-source` file in tmpfs, shredded
  after (step must have it, or it tries 123456 and burns a try).
- **No backup (accepted risk).** If the card is lost, broken or reset, the
  root is gone and every intermediate must be re-rooted under a new one.
  Nothing breaks at once: the bootstrap bundles anchor on their 5-year
  intermediates, and the workload intermediate lasts 2 years.
- **One card holds the sops admin identity and the root.** Losing it costs
  both. sops survives through `admin_backup` (a recipient of every file).
  A blocked PIN is unblocked with the PUK; while the PIN is blocked the
  card can't decrypt, so read the PUK from `secrets/admin.yaml` with
  `admin_backup`.

## Inventory of the legacy PKI (2026-10-31)

Taken read-only with
`openssl x509 -noout -subject -issuer -enddate -ext subjectAltName,keyUsage,extendedKeyUsage`
on the public certificates only. Locations: c4130 and r440
`/etc/nixos/tls/`, m2mini `/etc/nixos/mod/tls/`. Every host has the
same tree (`ca/`, `apiserver/{server,etcd-client,kubelet-client}/`,
`etcd/peer/`, `kubelet/{server,api-client}/`, `controller-manager/`,
`scheduler/`, `proxy/`; r440 also `kubectl/`), each with its `.json` CSR
config, `.csr`, cert and key.

### CAs

| CA | Subject | Issuer | Expires | SHA-256 (prefix) | Notes |
|---|---|---|---|---|---|
| etcd | `O=charlie's cloud, OU=solaris, CN=ETCD CA 1` | `CN=temp root` | 2036-08-03 | `44:9E:0B:F4:D2:B3` | intermediate, `pathlen:0`; identical on all 3 |
| k8s | `O=charlie's cloud, OU=solaris, CN=K8s CA 1` | `CN=temp root` | 2036-08-03 | `5F:26:6A:54:52:F9` | intermediate, `pathlen:0`; identical on all 3 |

The "temp root" is not on any node (only the intermediates are trusted, which
works because they are used as trust anchors directly). There is no
front-proxy CA.

### Leaves (all RSA, all expire 2027-08-04)

| Cert (path under `tls/`) | Subject | Signed by | EKU | SANs | Where |
|---|---|---|---|---|---|
| `etcd/peer/etcd.pem` | `CN=kube-etcd-peer` | etcd CA | server+client | `<node>`, `localhost`, `127.0.0.1` | per node (3 distinct) |
| `apiserver/server/api.pem` | `CN=kube-apiserver` | k8s CA | server | `r440`, `c4130`, `m2mini` (DNS only) | **one cert+key shared by all 3** |
| `apiserver/etcd-client/etcd.pem` | `CN=kube-apiserver-etcd-client` | etcd CA | client | – | per node |
| `apiserver/kubelet-client/{api,kubelet}.pem` | `O=system:cluster-admins, CN=kube-apiserver-kubelet-client` | k8s CA | client | – | per node |
| `controller-manager/api-client/api.pem` | `O=system:cluster-admins, CN=kube-controller-manager-api-client` | k8s CA | client | – | per node |
| `scheduler/api-client/api.pem` | `O=system:cluster-admins, CN=kube-scheduler-api-client` | k8s CA | client | – | per node |
| `kubelet/server/kubelet.pem` | `CN=kubelet` | k8s CA | server | `<node>`, `localhost`, `127.0.0.1` | per node |
| `kubelet/api-client/api.pem` | `O=system:cluster-admins, CN=kubelet-api-client` | k8s CA | client | – | per node |
| `proxy/api-client/api.pem` | `O=system:cluster-admins, CN=kube-proxy-api-client` | k8s CA | client | – | per node |
| `kubectl/api-client/api.pem` | `O=system:cluster-admins, CN=kubectl` | k8s CA | client | – | r440 only |

### Findings

1. **Every private key is in `/nix/store`** (world-readable). The configs use
   Nix paths (`certFile = ./tls/...`), so each key was copied into the store
   on every build. Treat every legacy key, including the apiserver key that
   also signs service-account tokens, as exposed. They are replaced, not
   reused.
2. **apiserver SAN gaps.** Only the three short names are present. The VIP
   `10.0.0.200`, the `kubernetes` service IP (old `192.0.0.1`, new
   `10.96.0.1`), `kubernetes.default[.svc[.cluster.local]]`, the LAN and
   tailnet IPs, the MagicDNS FQDNs (`*.leaffish-monster.ts.net`), `localhost`
   and `127.0.0.1` are all missing. In-cluster clients and anything using
   the VIP fail hostname verification.
3. **etcd and kubelet SAN gaps.** Only the short name and loopback. Names
   resolve through MagicDNS today, which works, but the FQDNs and the LAN or
   tailnet IPs do not verify.
4. **The etcd peer cert is also the etcd server cert** (`certFile` and
   `peerCertFile` both default to it). `peerClientCertAuth` is off.
5. **Identities only work with `AlwaysAllow`.** Every client cert is in
   `O=system:cluster-admins`, which is not a built-in group. Under
   `Node,RBAC` the kubelets need `system:node:<name>` in `system:nodes`,
   kube-proxy needs `system:kube-proxy`, and so on (see the table below).
6. **The service-account key is the apiserver TLS key**
   (`serviceAccountKeyFile = api.pem`, `serviceAccountSigningKeyFile = api-key.pem`).
7. Two different CAs sit behind one "temp root" whose key is not
   on the hosts. Nothing depends on the root, so it is dropped.

## New layout

### On the nodes: `/var/lib/kubernetes/secrets/`

Directory `root:root 0755`. Certificates and trust bundles are `root:root 0644`.
Each key is `0600` and owned by the user of the unit that reads it.

| File | Signed by | Profile (EKU) | Subject | SANs | Nodes (role) | Key owner |
|---|---|---|---|---|---|---|
| `ca.pem` | – | trust bundle, k8s CA(s) | | | all | – |
| `etcd-ca.pem` | – | trust bundle, etcd CA(s) | | | etcd, controlPlane | – |
| `front-proxy-ca.pem` | – | trust bundle | | | controlPlane | – |
| `sa.pub` / `sa.key` | – | RSA 2048 keypair | | | controlPlane | kubernetes |
| `etcd-peer-<n>` | etcd | peer (server+client) | `CN=<n>` | node | etcd | etcd |
| `etcd-server-<n>` | etcd | peer (server+client) | `CN=<n>` | node | etcd | etcd |
| `etcd-client-apiserver-<n>` | etcd | client | `CN=kube-apiserver-etcd-client` | – | controlPlane | kubernetes |
| `apiserver-<n>` | k8s | server | `CN=kube-apiserver` | node + apiserver | controlPlane | kubernetes |
| `apiserver-kubelet-client-<n>` | k8s | client | `CN=system:kube-apiserver` | – | controlPlane | kubernetes |
| `front-proxy-client-<n>` | front-proxy | client | `CN=front-proxy-client` | – | controlPlane | kubernetes |
| `controller-manager-<n>` | k8s | client | `CN=system:kube-controller-manager` | – | controlPlane | kubernetes |
| `scheduler-<n>` | k8s | client | `CN=system:kube-scheduler` | – | controlPlane | kubernetes |
| `addon-manager-<n>` | k8s | client | `CN=system:kube-addon-manager` | – | controlPlane | kubernetes |
| `admin-<n>` | k8s | client | `O=system:masters, CN=cluster-admin` | – | controlPlane | root |
| `kubelet-<n>` | k8s | peer (server+client) | `O=system:nodes, CN=system:node:<n>` | node | worker | root |
| `kube-proxy-<n>` | k8s | client | `O=system:node-proxier, CN=system:kube-proxy` | – | worker | root |
| `flannel-<n>` | k8s | client | `CN=flannel-client` | – | worker | root |

Every leaf is a pair: `<component>-<n>.pem` and `<component>-<n>-key.pem`.

- **node SANs**: `<n>`, `<n>.<domain>` (`*.leaffish-monster.ts.net`),
  the tailnet IP, the LAN IP, `127.0.0.1`, `localhost`, and the node's
  optional `extraSANs`.
- **apiserver SANs**: the node SANs, plus the VIP `10.0.0.200`, the
  `kubernetesServiceIP` `10.96.0.1`, `kubernetes`, `kubernetes.default`,
  `kubernetes.default.svc`, `kubernetes.default.svc.<clusterDomain>`, and
  `apiserverExtraSANs` (today `192.0.0.1`, the legacy `kubernetes` Service
  IP, as a stopgap until the Service-CIDR cut-over in
  [cluster-handoff](history/cluster-handoff-2026-10.md) step 3).
- **Subjects** and the RBAC that uses them:
  - `system:kube-apiserver` (the apiserver's kubelet client) is bound to
    `system:kubelet-api-admin` by `k8s/components/infra/rbac.nix` (catenix,
    `k8s/components/rbac.nix`). NixOS would create this binding through
    the addon manager, which is disabled here, so it must be applied with
    the admin cert during bootstrap; until then `kubectl logs/exec` get 403.
  - `flannel-client` and `system:kube-addon-manager` are **unused**: flannel
    runs as a DaemonSet with its own ServiceAccount and there is no addon
    manager. Nothing binds them (see the TODO in history/cluster-handoff-2026-10.md).
  - `system:node:<n>` is what the Node authorizer expects.
- **`etcd-server-<n>` also has client auth**, so `etcdctl` on a member can
  use it for health checks.
- **The CA keys and `ca-key.pem` stay on the operator machine.**
  controller-manager does not sign CSRs, so leave
  `clusterSigningCertFile` unset.
- **The kubelet node name must equal `<n>`**, the short hostname, for the
  Node authorizer.

### On the operator machine: `${XDG_DATA_HOME:-~/.local/share}/cluster-pki/<cluster>` (mode 0700)

The operator machine is r440, whose `/etc/nixos` is the checkout of this
repo. The live PKI there is `~admin/.local/share/cluster-pki/neurosis`
(outside the checkout; in charlie's home until stage 2 of charlie's removal,
docs/cluster.md). That is the tool's default `--out`
(`${XDG_DATA_HOME:-~/.local/share}/cluster-pki/<cluster name>`), so as
admin a plain `nix run /etc/nixos#cluster-pki` uses it. Below, `pki-out/`
means that directory. An `--out` under any directory that has `.git` or
`flake.nix` (a checkout) is refused.

**CA subjects and the cluster name.** cluster-pki puts `cluster.name` into
a CA's subject (`O=<name>, OU=cluster-pki, CN=<name> <ca> CA <date>`) only
when it creates that CA. The current CAs date from before the cluster was
renamed from solaris to neurosis, so they still read
`O=solaris, OU=cluster-pki, CN=solaris {k8s,etcd,front-proxy} CA 2026-10-31`,
and leaves they sign (renewals included) show that issuer. This is
expected: leaf subjects and SANs never contain the name, so nothing is
re-issued because of it. The next `--rotate-ca <ca> --phase begin` creates
a `neurosis <ca> CA <time>`. CAs made from now on carry the UTC time,
`CN=neurosis <ca> CA 2026-11-13T135157Z`, so two CAs of one kind made on the
same day (begin, abort, begin) never share a subject. Self-signed CAs keep
`OU=cluster-pki`; intermediates from `--ca-csr` are `O=neurosis` and the CN
only.

```
pki-out/
  .gitignore                 '*': the dir ignores itself
  ca/<k8s|etcd|front-proxy>/
    current/{ca.pem,ca-key.pem}   the signer
    next/                         new CA during a rotation (after begin);
                                  from --ca-csr: ca-key.pem + ca.csr, then
                                  ca.pem from --ca-import; .pending until begin
    previous/                     old CA during a rotation (after reissue)
    trust/<fp>.pem                adopted public certs (legacy CA)
    retired/<ts>/                 CAs dropped by finish/abort (kept, not deleted)
  ca.pem etcd-ca.pem front-proxy-ca.pem        trust bundles (deployed)
  ca-key.pem etcd-ca-key.pem front-proxy-ca-key.pem  -> ca/*/current/ca-key.pem
  sa.key sa.pub
  <component>-<node>.pem / -key.pem             leaves (deployed)
  backup/<ts>/                                  leaves replaced by a re-issue
```

Back up `pki-out/` encrypted and offline (no agenix yet). Losing the CA keys
means a full re-issue, which runs through the rotation runbook.

## cluster-pki usage

The definition is baked into the package as JSON when it is built, from
`cluster/definition.nix` through `builtins.toJSON`. Only the fields below are
read: `name`, `domain`, `vip`, `kubernetesServiceIP`, `clusterDomain`
(default `cluster.local`), `apiserverExtraSANs`, and per node `lanIP`,
`tailnetIP`, `roles` (`etcd`, `controlPlane`, `worker`), `extraSANs` and
`sshHost`. To try another definition, pass `--definition file.json`.

### cluster-pki

```
cluster-pki [--out DIR] [--renew] [--node NAME]
```

1. Creates any CA that is missing. An existing CA key is never overwritten.
   A missing CA whose intermediate was imported into `ca/<ca>/next/`
   (`--ca-csr`, `--ca-import`; a new cluster) becomes the current one.
   Otherwise it is self-signed, which is refused once a root is configured
   unless `--self-signed` is given ([Offline root](#offline-root-and-intermediate-cas)).
2. Creates the SA keypair if it is missing.
3. Rewrites the trust bundles.
4. Issues each leaf that is missing, is not signed by the current CA, has
   a subject, SANs or chain that differ from the definition, expires within
   30 days, or does not match its key. The old pair goes to `backup/<ts>/`.

A second run reports `0 issued`.

### status

```
cluster-pki status
```

Lists each leaf with its CA, expiry and state, and the subjects in each trust
bundle, then runs `check-anchors` and exits 1 if it fails.

### check-anchors

```
cluster-pki check-anchors
```

Enforces the anchor rule below. It fails when a trust bundle (`ca.pem`,
`etcd-ca.pem`, `front-proxy-ca.pem`):

- holds the root CA (`--root-ca`),
- holds a self-signed cert while that CA's `current` generation is an
  intermediate, other than its own `previous` generation (so rotating from
  an old self-signed CA to an intermediate passes: imported, begun,
  reissued, finished),
- holds a cert that is not one of its own CA's generations or an adopted
  `--trust` cert (this catches another branch's CA, the workload CA, or
  anything else), or lacks the current CA;

or when a leaf is not issued by one of its own CA's generations, or its
file carries a chain cert that is not one of them. `cluster-pki-deploy`
runs it too and refuses to copy anything when it fails.

### --trust

```
cluster-pki --trust etcd /path/legacy-etcd-ca.pem
```

Adds a **public** CA cert to the bundle. It refuses a file that holds a key,
and the root CA.

### Offline root and intermediate CAs

The three bootstrap CAs can be intermediates of an offline root whose key
is on a YubiKey (plan: `docs/pki-migration-plan.md`). cluster-pki never sees
the root key: it makes the intermediate's key and CSR, and imports the cert
the root signed elsewhere.

```
cluster-pki --ca-csr <etcd|k8s|front-proxy>
cluster-pki --ca-import <etcd|k8s|front-proxy> CERT.pem [--root-ca ROOT.pem]
```

- `--ca-csr` writes `ca/<ca>/next/ca-key.pem` (ECDSA P-384, 0600) and
  `ca/<ca>/next/ca.csr` (`O=neurosis, CN=neurosis <ca> CA <time>`,
  requesting `CA:TRUE, pathlen:0`, `keyCertSign, cRLSign`), and prints the
  public key's SHA-256 to compare at the signing machine. The CSR is public.
  It refuses while `next/` or `previous/` exists (`--phase abort` discards
  a CSR you don't want).
- Sign it as the root with critical `basicConstraints = CA:TRUE, pathlen:0`
  and `keyUsage = keyCertSign` (plus `cRLSign`), e.g. 5 years. A
  software-key test: `openssl x509 -req -in ca.csr -CA root.pem -CAkey
  root.key -days 1825 -sha384 -extfile ext` with those lines in `ext`.
- `--ca-import` accepts exactly one cert (no chain, no key) whose public key
  is the `next/` key, with critical `CA:TRUE, pathlen:0` and keyCertSign,
  that verifies against the root, and is not the root. It warns if the cert
  expires before a fresh leaf would (cfssl does not shorten leaves to the
  CA's lifetime). It installs `next/ca.pem`, but trust bundles do not
  change until `--rotate-ca <ca> --phase begin`. With no current CA (a new
  cluster), the next `cluster-pki` run makes it the current one.
- The root is `cluster/pki/root-ca.pem` in this repo (public). When that
  file exists, the package bakes it in (`CLUSTER_PKI_ROOT_CA`); `--root-ca
  FILE` overrides it.
- **Self-signed CAs stay the default until the root exists.** With no root
  configured, a missing CA and `--phase begin` self-sign as before. Once
  `cluster/pki/root-ca.pem` is committed, both refuse to self-sign and ask
  for `--ca-csr`/`--ca-import`; `--self-signed` forces the old path (e.g.
  break-glass with the YubiKey unavailable). It doesn't apply to an
  existing CA: today's self-signed CAs keep signing until they are rotated.
- Leaves stay RSA 2048, signed with ecdsa-with-SHA384 by a P-384
  intermediate. **Server leaves** (profiles server and peer: `apiserver`,
  `etcd-peer`, `etcd-server`, `kubelet`) of an intermediate carry the chain,
  leaf + intermediate, in `<component>-<n>.pem`, so clients that trust only
  the root can verify them. Client leaves are the leaf only.
- **Anchor rule.** Trust bundles hold only that CA's intermediate(s)
  (current, next and previous during a rotation), never the root and never
  another branch's CA: a bundle with the root would also accept anything
  the workload intermediate (key in etcd) signs, `system:masters` client
  certs included. etcd, the apiserver and the kubelet are Go, and Go's
  `x509.Verify` accepts a non-self-signed cert in the root pool as an
  anchor. OpenSSL does not by default: check by hand with
  `openssl verify -partial_chain -CAfile ca.pem <leaf>.pem` (cluster-pki
  and `cluster-pki-deploy` do).

### --rotate-ca

```
cluster-pki --rotate-ca <etcd|k8s|front-proxy> --phase <phase>
```

The phases are `begin`, `reissue`, `finish`, `abort` and `rollback`. See the
runbook below. With an offline root, `begin` takes the intermediate that
`--ca-csr`/`--ca-import` put in `next/` instead of self-signing one:

```sh
cluster-pki --ca-csr front-proxy              # copy ca/front-proxy/next/ca.csr to the root
cluster-pki --ca-import front-proxy fp.pem    # the signed intermediate
cluster-pki --rotate-ca front-proxy --phase begin   # bundle = old + new
```

`begin` refuses while `next/` holds only a CSR, and `reissue` refuses
before `begin`. `abort` retires a pending CSR or import like any next CA.

### cluster-pki-deploy

```
cluster-pki-deploy <node> [--host H] [--staging DIR] [--dry-run]
```

1. Runs `check-anchors`, then verifies every leaf for the node against its
   bundle on the local machine.
2. Streams the files with `tar | ssh` to `~/<staging>/<node>/` (default
   `cluster-pki-staging`, mode 0700/0600), as the same user on the node
   (admin: plain `ssh <node>` from admin on r440, through Tailscale SSH;
   the tailnet SSH policy must allow admin from r440 to the node).
   This works with fish as the login shell (admin's on m2mini), and needs
   neither rsync nor sudo.
3. Prints the exact `sudo install -m … -o … -g …` commands to paste into
   `ssh -t <node> bash`, then the restart and health-check commands. It
   never runs sudo itself.

## Cut-over from the legacy PKI

The legacy keys are exposed (finding 1), so the cut-over moves to new CAs
rather than re-signing with the old ones. The legacy CA keys are not used at
all.

- **etcd: soft cut-over, no quorum loss.** It is the rotation below, with the
  legacy `ETCD CA 1` as the old CA:

  ```sh
  scp r440:/etc/nixos/tls/ca/etcd.pem /tmp/legacy-etcd-ca.pem   # public cert (done 2026-10-31)
  cluster-pki                                         # new CAs + leaves
  cluster-pki --trust etcd /tmp/legacy-etcd-ca.pem    # etcd-ca.pem = new + legacy
  ```

  Then run steps 1 to 3 of the runbook, skipping `--phase begin` and
  `--phase reissue`: the leaves from the first run are already signed by the
  new CA. The two intermediate states are selected per node with
  `cluster.nodes.<n>.rollout.etcdPhase` (option `clusterNode.etcd.phase`):
  - `"trust"` (runbook step 1): `etcd-ca.pem` (new + legacy) is trusted, but
    the member still presents the **legacy** leaf, copied out of
    `/etc/nixos/tls` into the secrets dir as `legacy-etcd-peer-<n>{,-key}.pem`
    (and `legacy-etcd-client-apiserver-<n>{,-key}.pem` on control planes);
    `peerClientCertAuth` stays off, as today. The legacy keys are already
    exposed (finding 1), so copying them is no new exposure; they are
    deleted after step 3.
  - `"final"` (runbook step 2): `etcd-{server,peer}-<n>` and
    `etcd-client-apiserver-<n>`, `peerClientCertAuth` on. Switch a member to
    `"final"` only when **all three** run `"trust"`.

  Step 3 is `--phase finish`, which drops the legacy CA from the bundle.
  The exact commands per node are in
  [cluster-handoff](history/cluster-handoff-2026-10.md) step 2.

  Switching a node straight from the legacy config to `"final"` is a hard
  cut-over: the legacy members trust only `ETCD CA 1` and reject its new
  leaf, so that member (and its apiserver) is cut off until a second member
  is switched, and quorum hangs on the third. Don't.
- **Kubernetes: hard cut-over.** It happens in the same window as the move
  to `Node,RBAC` and the new pod and service CIDRs.
  - Every legacy client identity stops being authorized under RBAC anyway.
  - Switch one node at a time: control planes first, then m2mini.
  - Old kubeconfigs stop working. Use `admin-<n>` with the VIP.
  - If legacy clients must keep working during the window, run
    `cluster-pki --trust k8s legacy-k8s-ca.pem`, and later
    `--rotate-ca k8s --phase finish` to drop it.
- **Service CIDR (192.0.0.0/24 → 10.96.0.0/12).** etcd keeps the legacy
  `kubernetes` ServiceCIDR object and the `default/kubernetes` Service at
  `192.0.0.1`; ClusterIP is immutable and the apiserver only reconciles
  the Service's ports, so new flags alone don't move it. Until the
  cut-over step (delete the Service, migrate the ServiceCIDR; exact
  commands in [cluster-handoff](history/cluster-handoff-2026-10.md) step 3d) pods get
  `KUBERNETES_SERVICE_HOST=192.0.0.1`, which is why the apiserver leaves
  carry `192.0.0.1` as a stopgap SAN (`apiserverExtraSANs`). Run that step
  before flannel/CoreDNS/Flux are applied, then drop the SAN and re-issue.
  Stale `Node` objects with a `podCIDR` outside `10.244.0.0/16` must be
  deleted in the same step (`spec.podCIDR` is immutable too).
- **Service accounts.** The new `sa.key` replaces the legacy key, so tokens
  signed with the old key stop verifying. Projected tokens are re-minted by
  the kubelet. Legacy Secret-based tokens must be recreated.

## etcd CA rotation runbook (no quorum loss)

Three members, so quorum is 2. Change **one member at a time** and continue
only when all three are healthy. etcd verifies its peers against
`peerTrustedCaFile` (`trustedCaFile` by default) and its clients against
`trustedCaFile` (`clientCertAuth = true`). The apiservers verify etcd against
`etcd.caFile`. Every party must therefore trust a CA before any party
presents a cert signed by it.

### Health check

Run this after every single-member change, from any member:

```sh
D=/var/lib/kubernetes/secrets; n=$(hostname)
sudo etcdctl --endpoints=https://r440:2379,https://c4130:2379,https://m2mini:2379 \
  --cacert=$D/etcd-ca.pem --cert=$D/etcd-server-$n.pem --key=$D/etcd-server-$n-key.pem \
  endpoint health --cluster -w table        # all 3 "true"
sudo etcdctl ... endpoint status --cluster -w table   # 1 leader, raft index moving
sudo journalctl -u etcd --since -5min | grep -iE 'tls|x509|handshake'   # empty
```

During the legacy cut-over, before `etcd-server-<n>` is installed, use the
apiserver etcd client cert, or the old member cert, for `--cert` and
`--key`: in the `"trust"` phase that is
`$D/legacy-etcd-peer-$n.pem` / `$D/legacy-etcd-peer-$n-key.pem`.

If any check fails, stop and roll back the last member only. The other two
still hold quorum.

### Step 0: prepare (operator machine)

```sh
cluster-pki --rotate-ca etcd --phase begin   # (legacy cut-over: --trust instead)
cluster-pki status                           # bundle shows old + new subjects
```

### Step 1: trust bundle everywhere (leaves unchanged)

For each node, in the order **m2mini → c4130 → r440** (followers first,
current leader r440 last):

1. `cluster-pki-deploy <node>` installs the new `etcd-ca.pem` bundle. The
   other files are re-installed unchanged.
2. Point `services.etcd.trustedCaFile` (and the peer CA) and, on control
   planes, `services.kubernetes.apiserver.etcd.caFile` at
   `/var/lib/kubernetes/secrets/etcd-ca.pem`. Leave the cert and key options
   on the old leaves. Build, then `switch`. With this flake that is
   `rollout.etcdPhase = "trust"` for the node in `cluster/definition.nix`
   (the legacy cut-over; for a later CA rotation every node is already
   `"final"` and only the bundle file changes, so restart instead).
3. If only the file changed, restart instead:
   `sudo systemctl restart etcd`, and on control planes also
   `kube-apiserver`.
4. Run the health check. Then continue with the next node.

After step 1 every member and apiserver trusts both CAs, while every party
still presents an old leaf.

### Step 2: new leaves, one member at a time

1. `cluster-pki --rotate-ca etcd --phase reissue` (operator machine). The
   new CA becomes the signer and all etcd leaves are re-issued. The old ones
   go to `backup/<ts>/`, and the bundle stays old + new.
2. For each node, in the same order:
   1. `cluster-pki-deploy <node>`.
   2. Set `certFile`/`keyFile` to `etcd-server-<n>`, `peerCertFile` and
      `peerKeyFile` to `etcd-peer-<n>`, and on control planes
      `apiserver.etcd.{certFile,keyFile}` to `etcd-client-apiserver-<n>`.
      Then switch, or restart `etcd` (and `kube-apiserver`). With this
      flake: `rollout.etcdPhase = "final"` for the node (this also turns
      `peerClientCertAuth` on for it).
   3. Run the health check. A member with new leaves must still talk to the
      members with old leaves. It does, because everyone trusts both CAs.

`peerClientCertAuth = true` can be enabled now, one member at a time with a
health check after each. Every peer cert, old or new, has client auth and
chains to the bundle.

### Step 3: drop the old CA

1. `cluster-pki --rotate-ca etcd --phase finish`. This moves `previous/`
   and `trust/*` to `retired/<ts>/`, so the bundle is the new CA only.
2. Before deploying, confirm that no live member or apiserver still presents
   an old leaf. On each node, run
   `openssl x509 -noout -issuer -in /var/lib/kubernetes/secrets/etcd-*-<n>.pem`,
   and check that nothing still points at a `/nix/store/...tls` path:
   `systemctl cat etcd | grep -i file`.
3. For each node, one at a time: `cluster-pki-deploy <node>`,
   `sudo systemctl restart etcd` (and `kube-apiserver` on control planes),
   then the health check.

### Rollback

| Failed during | Do |
|---|---|
| Step 1, on one node | Revert that node's config (previous generation: `nixos-rebuild switch --rollback`, or restore the old `etcd-ca.pem` from the staging copy) and restart etcd. The others are unaffected: they trust a superset. |
| Before Step 2 started | `cluster-pki --rotate-ca etcd --phase abort` retires the new CA, so the bundle is the old CA only. Redeploy it node by node; that is harmless, because nobody presents a new leaf. |
| Step 2, on one node | Put back that node's old leaves: `--phase rollback` restores `backup/<ts>/` and the old CA signs again, then `cluster-pki-deploy <node>`. Or roll back the node's NixOS generation. Restart and run the health check. The bundle still holds both CAs, so the mixed state is valid. `rollback` resets *all* etcd leaves in `pki-out/`, so run `--phase reissue` again and redeploy every node before going on. To roll back a single node without that, install its files from `pki-out/backup/<ts>/` by hand. |
| After Step 3 | No rollback needed for the leaves: everyone presents new leaves. To re-trust the old CA, `cluster-pki --trust etcd pki-out/ca/etcd/retired/<ts>/ca/ca.pem` and redeploy the bundle node by node. |
| Quorum lost anyway (2 members down) | Do not touch the third member. Revert the most recently changed member to its previous NixOS generation; that restores the old cert paths, and the bundle file is still on disk. Restart it, and quorum returns with 2 of 3. Then fix the other one. etcd data is never touched by any step; no `member remove/add`, and names and peer URLs are unchanged. |

Before step 1, take a snapshot on a healthy member as a safety net (it is not
used by the runbook):
`sudo etcdctl --endpoints=https://$(hostname):2379 ... snapshot save /var/lib/etcd-snap-$(date +%F).db`
(exactly one endpoint: `snapshot save` rejects a list).

The same procedure works for the k8s CA, with the apiserver, kubelet and
clients in place of the members, and for the front-proxy CA (apiserver only).

## Phase 2 operations

cert-manager issues the bootstrap leaves in the cluster
([plan](pki-migration-plan.md), phase 2). Hosts keep using files until
each one switches to `certSource = "sops"`.

- Namespace `cluster-pki`: component `infra/cluster-pki`, applied by
  `flux-system`. It holds the export job too.
- Issuers, Certificates, policies: component `infra/cluster-pki-issuers`,
  Kustomization `cluster-pki-issuers` (deferred, like cert-manager's
  issuers).
- The leaves come from `cluster/definition.nix` through
  `k8s/components/infra/cluster-pki/leaves.nix`. They are the leaves
  `cluster-pki` makes, flannel-* and addon-manager-* included.

### Issuers and approver-policy

- Issuers `k8s-ca`, `etcd-ca`, `front-proxy-ca` are CA issuers over the
  Secrets of the same names in `cluster-pki`: `tls.crt` the intermediate
  (`cluster/pki/<name>.pem`), `tls.key`, `ca.crt` the root. They come from
  `k8s/secrets/cluster-pki/<name>.sops.yaml` (P6). Until then the Issuers,
  the Certificates and `cluster-pki-issuers` are NotReady. Nothing else is
  affected.
- One Certificate per leaf, `<component>-<node>`, with a Secret of the same
  name. Same CN, O, SANs and usages as `cluster-pki`. RSA 2048 (PKCS#1, a
  new key at every renewal), 8760h, renewed 720h before expiry. Labels
  `pki.neurosis/node` and `pki.neurosis/ca`, on the Secret too.
- The Secret's `tls.crt` is the leaf then the intermediate, for every leaf.
  `cluster-pki` appends the intermediate only to server and peer leaves.
- cert-manager's own auto-approver is off (`disableAutoApproval`).
  approver-policy approves a request when a policy whose selector matches
  allows every field, and the requester may `use` that policy. The
  requester is always cert-manager's controller.
- `cluster-ca` (workloads) has one allow-all policy, minus CA certs. RBAC:
  ClusterRole `cert-manager-policy:cluster-ca`.
- `cluster-pki` has one policy per leaf, `cluster-pki-<component>-<node>`.
  It allows exactly that leaf: the CN, the O if any, only its SANs and
  usages, RSA 2048, at most 8760h, no CA. Everything else is denied. So the
  k8s CA signs `O=system:masters` only with `CN=cluster-admin`, and
  `system:node:<n>` only for the nodes in the definition. RBAC: Role
  `cert-manager-policy:cluster-pki`.
- approver-policy reads `*` as a wildcard. The render fails if a leaf value
  contains one.
- approver-policy's webhook validates the policies with failurePolicy
  Fail, so the policies live in the deferred components. The webhook
  serves its own cert (Secret `cert-manager-approver-policy-tls`, declared
  empty by the chart, filled by the controller).
- Changing a leaf in `cluster/definition.nix` changes its Certificate and
  its policy in one render. cert-manager reissues it; the export job
  brings it to the hosts.

### Export job

- CronJob `cluster-pki/pki-export`, daily at 09:41 New York time. Code:
  `pkgs/pki-tools` (Python; `pki/cli_export.py`). The expected leaves are
  baked into the package from `leaves.nix` (`PKI_LEAVES_JSON`);
  `PKI_EXPORT_SECRETS`, set by the CronJob, narrows them to its list.
  Other environment: `PKI_EXPORT_TOKEN_FILE`, `GITHUB_REPOSITORY`.
- It gets each leaf Secret by name and writes `secrets/pki/<node>.yaml`:
  certs in plaintext, keys sops-encrypted to the admins and that host. It
  validates each node (chain, node, completeness, expiry). When
  fingerprints differ from `main` it pushes `pki-renew/<date>` and opens a
  PR. Merging is a human step.
- Its Role allows `get` on the leaf Secrets only. It has no `list`: RBAC
  cannot limit `list` by name. The CA Secrets in the same namespace stay
  unreadable to it.
- Non-root (65532), read-only root fs, no capabilities. `/tmp` is a
  memory-backed emptyDir; the keys pass through it in plaintext. The
  image holds no age identity.
- The image is amd64 only. The job has an amd64 nodeSelector, and
  `k8s/render.nix` exempts it from the multi-arch check.
- Local runs: `nix run .#pki-export -- --from-dir DIR --dry-run
  --repo-dir . --out OUT` (Secret YAML files in, no cluster, no git, no
  API). `nix build .#pki-export-image` is a `docker-archive` stream:
  `./result | skopeo copy docker-archive:/dev/stdin …`. Tests: `nix build
  .#checks.x86_64-linux.pki-tools` (pytest; also in `nix flake check`).

### Export job: GitHub token

The job reads Secret `cluster-pki/pki-export-github`, key `token`, from
`k8s/secrets/cluster-pki/pki-export-github.sops.yaml`. It is not in git
yet. To create it (an admin, with the YubiKey):

1. GitHub > Settings > Developer settings > Fine-grained tokens. Resource
   owner charlie-horse, "Only select repositories": charlie-horse/flake.
   Permissions: Contents read and write, Pull requests read and write
   (Metadata read is implied). Nothing else. Expiry at most a year; put a
   reminder in `docs/cluster.md`.
2. From the dev shell, run
   `sops k8s/secrets/cluster-pki/pki-export-github.sops.yaml`. Never put
   the token on a command line; `sops` opens `$EDITOR`. Content:

   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: pki-export-github
     namespace: cluster-pki
   type: Opaque
   stringData:
     token: <the token>
   ```

   The `k8s/secrets` rule in `.sops.yaml` encrypts `stringData` to the
   admins and Flux.
3. Add a row to `docs/cluster.md`, "Secrets (all of them)".
4. PR, merge. The Flux Kustomization `secrets` creates it.

### Activating the export job

The CronJob is suspended while `digest` in
`k8s/components/infra/cluster-pki/export.nix` is `null`.

1. The token Secret exists (above).
2. The CA Secrets are merged and the Issuers are Ready (P6).
3. `.github/workflows/pki-export-image.yml` builds the image on every PR
   that touches it. On `main` it pushes
   `ghcr.io/charlie-horse/flake/pki-export` with tags `<sha12>` and
   `main`, and prints the digest in the step summary.
4. The GHCR package must be public: the cluster has no pull secret (like
   `charlie-horse/flake/manifests`, `docs/ci.md`).
5. Set `digest = "sha256:…";` in `export.nix`. PR, merge. That unsuspends
   the CronJob.

A new image never reaches the cluster without a PR that moves the pin. To
suspend the job again, set `digest = null;`.

### Hosts on sops (`certSource`)

- Set `rollout.certSource = "sops"` for the node in
  `cluster/definition.nix` (`modules/cluster/pki-sops.nix`). It needs
  etcdPhase `"final"` and a merged `secrets/pki/<node>.yaml`; both are
  asserted.
- Files are under `/run/secrets/pki` (sops-nix's ramfs, a new generation
  at every activation, before any unit starts):
  - `<component>-<node>.pem` / `-key.pem` from `secrets/pki/<node>.yaml`.
  - `sa.key` / `sa.pub` (controlPlane) from `secrets/cluster-sa.yaml`,
    one file for every control plane (admins + the three hosts).
  - `ca.pem`, `etcd-ca.pem`, `front-proxy-ca.pem` from `cluster/pki/` in
    git, as sops templates (0644 root).
- The file set is what `cluster-pki deploy` installs, unused leaves
  included. The module asserts `leaves.nix` agrees with SPECS in
  `cluster-pki.sh`.
- Owners and modes follow `cluster-pki`'s `node_files`. `restartUnits`
  restarts the readers of a changed file; units not enabled on the host are
  left out.
- The values have no trailing newline (the export job writes `|-`). Every
  reader (etcd, kube-*) is Go and parses PEM without one.

### Comparing with cluster-pki (`pki-diff`)

The dry run (P7) compares one node's `cluster-pki` leaves with the
cert-manager set. It reads only the plaintext certs:

```sh
nix run .#pki-diff -- ~/.local/share/cluster-pki/neurosis secrets/pki/r440.yaml
```
