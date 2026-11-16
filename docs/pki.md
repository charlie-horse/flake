# Cluster PKI

The cluster (etcd + Kubernetes on c4130, r440 and m2mini) uses three
bootstrap CAs (k8s, etcd, front-proxy), a service-account keypair and one
set of leaf certificates per node. cert-manager issues the leaves in the
cluster, an export job puts them into git as sops files, and sops-nix
installs them in `/run/secrets/pki/` on each node
([Where certs come from](#where-certs-come-from)). Nothing secret is a Nix
path, in `/nix/store`, or in git unencrypted. The inventory of every secret
(PKI and the rest) is `docs/cluster.md`, "Secrets (all of them)".
The old operator-side tool `cluster-pki` (removed in phase 2's P9,
2026-11-16) and its procedures are in git history
(`git show aea861e:docs/pki.md`) and [docs/history](history/cluster-handoff-2026-10.md).

```sh
sudo kubectl --kubeconfig /etc/kubernetes/admin.kubeconfig get nodes   # break-glass, any node
```

- [Bootstrap PKI and workload PKI](#bootstrap-pki-and-workload-pki)
- [YubiKey root CA](#yubikey-root-ca)
- [Where certs come from](#where-certs-come-from)
- [Break-glass](#break-glass)
- [Offline signing when the cluster is down](#offline-signing-when-the-cluster-is-down)
- [CA rotation](#ca-rotation)
- [Phase 2 operations](#phase-2-operations)
- [Inventory of the legacy PKI](#inventory-of-the-legacy-pki-2026-10-31)

## Bootstrap PKI and workload PKI

**Status (2026-11-16):** every CA is a neurosis intermediate under the
YubiKey root (bootstrap CAs rotated in 2026-11-13), and all three nodes
read their certs from sops (P8). The migration is complete
([plan](pki-migration-plan.md)).

There is one root CA with two branches. The branches never share an
intermediate.

```
neurosis Root CA 2026          admin YubiKey (19830800) slot 9c, P-384, 20 y, pathlen:1
├── workload branch
│   └── neurosis workload CA       Secret cert-manager/cluster-ca (sops), P-384, 2 y, pathlen:0
│         └── workload leaves      ClusterIssuer cluster-ca
└── bootstrap branch (Issuers in namespace cluster-pki)
    ├── neurosis k8s CA            Secret cluster-pki/k8s-ca (sops), 5 y, pathlen:0 → apiserver, kubelet, admin, ...
    ├── neurosis etcd CA           Secret cluster-pki/etcd-ca (sops), 5 y, pathlen:0 → etcd server/peer/client
    └── neurosis front-proxy CA    Secret cluster-pki/front-proxy-ca (sops), 5 y, pathlen:0 → front-proxy-client
```

| | Bootstrap branch | Workload branch |
| --- | --- | --- |
| For | etcd, kube-apiserver, controller-manager, scheduler, kubelet, kube-proxy, flannel client, front-proxy, service-account keys, admin kubeconfig | TLS for workloads in the cluster |
| Made by | cert-manager Issuers `k8s-ca`, `etcd-ca`, `front-proxy-ca` in namespace `cluster-pki` ([Phase 2 operations](#phase-2-operations)) | cert-manager in the cluster (`k8s/components/infra/cert-manager/`, [k8s/README.md](../k8s/README.md#cert-manager)) |
| CAs | k8s, etcd, front-proxy intermediates signed by the root (5 y, to 2031-11-13). Keys sops-encrypted in git (`k8s/secrets/cluster-pki/<ca>-ca.sops.yaml`), applied by the Flux Kustomization `secrets` | `cluster-ca`, the workload intermediate signed by the root (2 y, to 2028-11-12). Its key is sops-encrypted in git (`k8s/secrets/cert-manager/cluster-ca.sops.yaml`), applied by the Flux Kustomization `secrets` |
| Trusts | its own intermediate only ([anchor rule](#the-anchor-rule)) | the root |
| Delivered as | files in `/run/secrets/pki/` on each node, from `secrets/pki/<node>.yaml` through sops-nix | Secrets, issued on request (`issuerRef: {kind: ClusterIssuer, name: cluster-ca}`) |

The service-account keypair is a bare keypair, not a certificate. It is
outside the hierarchy.

**Why the hosts read files, not the cluster.** cert-manager is a set of
pods. Pods need a kubelet registered with an apiserver, that apiserver
needs etcd and its serving cert, the kubelet needs its client cert, and the
pod network (flannel) needs its own. So cert-manager only issues the host
leaves; they reach the hosts as files through a PR that a human merges.
A host boots and its control plane starts with the cluster down. The
cluster is needed only to renew, 30 days before a one-year leaf expires; if
it can't, [sign offline](#offline-signing-when-the-cluster-is-down).

**Why the workload branch has its own intermediate.** `cluster-ca` is a
ClusterIssuer: a Certificate in any namespace can use it. The k8s CA signs
`system:masters` and `system:node:*` client certs, so its key behind such
an issuer would hand out cluster-admin. The bootstrap Issuers are
namespaced (only Certificates in `cluster-pki` can use them) and
approver-policy allows exactly the leaves in `cluster/definition.nix`. The
workload intermediate signs nothing the apiserver or etcd trust, so a leak
of it compromises workload TLS only. That holds only because of the anchor
rule.

**Workload intermediate renewal is manual.** cert-manager does not renew a
CA Secret it did not issue. It expires 2028-11-12; about 60 days before
(around 2028-09-13), sign a new one with the root
([how](#signing-an-intermediate-under-the-existing-root)) and replace the
sops file (PR, merge; Flux applies it). Leaf durations must stay under its
remaining life.

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
  node (see the inventory below). OpenSSL does not by default: check by
  hand with `openssl verify -partial_chain -CAfile ca.pem <leaf>.pem`.
- Server leaves ship the full chain (leaf + intermediate) in the cert file,
  so clients that trust only the root (browsers, workloads) can verify them.
- Only workloads trust the root itself, plus a trust-manager bundle if one
  is added.
- The bundles are `cluster/pki/{k8s,etcd,front-proxy}-ca.pem` from git,
  never from the cluster. The export job refuses a leaf that does not chain
  to exactly its own intermediate (the root and the workload CA included).

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
| In git (public) | `cluster/pki/`: the root cert `root-ca.pem`, the slot attestation `attest-9c.pem` (it chains to the card's attestation cert `attest-f9.pem`: the key was generated on the card and cannot be exported), the four intermediate certs `{k8s,etcd,front-proxy,workload}-ca.pem` (the bootstrap ones are also the hosts' trust bundles) and `fingerprints.txt` |
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

## Where certs come from

```
cluster/definition.nix → leaves.nix → Certificate <component>-<node> (namespace cluster-pki)
  → Issuer k8s-ca | etcd-ca | front-proxy-ca, approved by approver-policy → Secret <component>-<node>
  → CronJob pki-export (daily) → PR pki-renew/<date> with secrets/pki/<node>.yaml → merge (you)
  → git pull && switch, one host at a time → sops-nix → /run/secrets/pki/
```

cert-manager renews 30 days before expiry and the export job opens a PR
within a day. Merge it and switch each host ([cluster.md, Changing a host](cluster.md#changing-a-host));
`restartUnits` restarts only the readers of a changed file. If a renewal
PR sits unmerged, the CronJob starts failing once a cert on `main` is
within 14 days of expiry: a failed `pki-export` run is the signal.

### On the nodes: `/run/secrets/pki/`

`modules/cluster/pki-sops.nix`. sops-nix's ramfs, a new generation at
every activation, before any unit starts. Certificates and trust bundles
are `root:root 0644`; each key is `0600` and owned by the user of the unit
that reads it.

- `<component>-<node>.pem` / `-key.pem` from `secrets/pki/<node>.yaml`
  (certs plaintext, keys sops-encrypted to the admins and that host).
- `sa.key` / `sa.pub` (controlPlane) from `secrets/cluster-sa.yaml`, one
  file for every control plane. Not a cert; it never renews.
- `ca.pem`, `etcd-ca.pem`, `front-proxy-ca.pem` from
  `cluster/pki/{k8s,etcd,front-proxy}-ca.pem` in git, as sops templates.
- The values have no trailing newline (the export job writes `|-`). Every
  reader (etcd, kube-*) is Go and parses PEM without one.

| File | Signed by | Profile (EKU) | Subject | SANs | Nodes (role) | Key owner |
|---|---|---|---|---|---|---|
| `ca.pem` | – | trust bundle, k8s CA | | | all | – |
| `etcd-ca.pem` | – | trust bundle, etcd CA | | | etcd, controlPlane | – |
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
  `apiserverExtraSANs` (today `kube-api.leaffish-monster.ts.net`, the
  Tailscale Service).
- **Subjects** and the RBAC that uses them:
  - `system:kube-apiserver` (the apiserver's kubelet client) is bound to
    `system:kubelet-api-admin` by `k8s/components/infra/rbac.nix` (catenix,
    `k8s/components/rbac.nix`). NixOS would create this binding through
    the addon manager, which is disabled here, so on a fresh cluster it
    must be applied with the admin cert; until then `kubectl logs/exec`
    get 403.
  - `flannel-client` and `system:kube-addon-manager` are **unused**: flannel
    runs as a DaemonSet with its own ServiceAccount and there is no addon
    manager. Nothing binds them (see the TODO in history/cluster-handoff-2026-10.md).
  - `system:node:<n>` is what the Node authorizer expects.
- **`etcd-server-<n>` also has client auth**, so `etcdctl` on a member can
  use it for health checks.
- **No CA key is on a node.** controller-manager does not sign CSRs, so
  `clusterSigningCertFile` stays unset.
- **The kubelet node name must equal `<n>`**, the short hostname, for the
  Node authorizer.

## Break-glass

Every node has `/etc/kubernetes/admin.kubeconfig`, readable by root only:
user `cluster-admin` (`O=system:masters`) with the node's
`/run/secrets/pki/admin-<n>.pem`, server the VIP `https://10.0.0.200:6443`.
It follows the admin cert's renewals; nothing to regenerate or copy. It
works without authentik:

```sh
sudo kubectl --kubeconfig /etc/kubernetes/admin.kubeconfig get nodes
sudo kubectl --kubeconfig /etc/kubernetes/admin.kubeconfig -s https://127.0.0.1:6443 get nodes   # VIP down
```

People use OIDC ([k8s/README.md](../k8s/README.md#authentik)). The admin
cert never leaves the node; a cloud session runs no sudo, so it has no
cluster credentials.

## Offline signing when the cluster is down

If cert-manager can't renew (the cluster is down and a leaf is about to
expire, or has), an admin signs the leaf with the intermediate from sops.
On any machine with a checkout and the YubiKey (on a server: `sudo -i`,
then `ca-pcscd &`; [YubiKey root CA](#yubikey-root-ca)) or `admin_backup`.
Keys only in tmpfs:

```sh
nix shell /etc/nixos#ca-ceremony-tools       # step, sops, yq, openssl
t=$(mktemp -d -p /dev/shm) && cd "$t"
s=/etc/nixos/k8s/secrets/cluster-pki/k8s-ca.sops.yaml   # or etcd-ca, front-proxy-ca
sops -d "$s" | yq '.data."tls.crt"' | base64 -d > ca.pem
(umask 077; sops -d "$s" | yq '.data."tls.key"' | base64 -d > ca-key.pem)
# subject and SANs as in the table above, or from the old cert:
#   openssl x509 -noout -subject -ext subjectAltName -in /run/secrets/pki/<leaf>.pem
openssl req -new -newkey rsa:2048 -nodes -keyout leaf-key.pem -out leaf.csr \
  -subj '/O=system:nodes/CN=system:node:r440' -addext 'subjectAltName=DNS:r440,IP:127.0.0.1,…'
step certificate sign leaf.csr ca.pem ca-key.pem --bundle --not-after 720h > leaf.pem
```

- Quick, until the next activation: copy the pair to the node and
  `sudo install` it over `/run/secrets/pki/<leaf>.pem` (`-m 0644 -o root`)
  and `-key.pem` (`-m 0600 -o <key owner>`), then restart its unit.
- To keep it: on a branch, write both into `secrets/pki/<node>.yaml` with
  `jq -Rs . < leaf-key.pem | sops set --value-stdin secrets/pki/<node>.yaml '["<leaf>-key.pem"]'`
  (the cert likewise), PR, merge, switch.
- `shred -u "$t"/*` when done. Once the cluster is back, the export job's
  next PR replaces the leaf with cert-manager's.

## CA rotation

A bootstrap intermediate (to 2031-11-13) is replaced by a new one under the
same root: trust first, then leaves, then drop the old CA. Every switch is
one host at a time with the etcd check and `readyz` after each
([cluster.md, Changing a host](cluster.md#changing-a-host)).

- **Sign:** in tmpfs, a new P-384 key and CSR
  (`O=neurosis, CN=neurosis <ca> CA <date>`), signed by the root in slot 9c
  ([how](#signing-an-intermediate-under-the-existing-root)).
- **PR 1, trust and signer:** `cluster/pki/<ca>-ca.pem` becomes new + old
  (new first: the export job checks leaves against the first cert, so it
  reports the old leaves until the next step), `fingerprints.txt`, and
  `k8s/secrets/cluster-pki/<ca>-ca.sops.yaml` with the new `tls.crt` and
  `tls.key`, encrypted straight from tmpfs. Merge: Flux gives the Issuer
  the new key, and each host's switch installs the two-CA bundle.
- **New leaves:** after the last host, `cmctl renew -n cluster-pki -l pki.neurosis/ca=<ca>`,
  then `kubectl -n cluster-pki create job --from=cronjob/pki-export pki-export-now`;
  merge its PR and switch every host.
- **PR 2:** drop the old cert from `cluster/pki/<ca>-ca.pem`, switch every
  host. For k8s and front-proxy, delete
  `kube-system/extension-apiserver-authentication` once after: the
  apiserver never removes old CAs from it.

### Signing an intermediate under the existing root

`ca-ceremony` (`pkgs/ca-ceremony-tools/ceremony.sh`) is the first-time root
ceremony: it refuses to run while slot 9c holds a key and always creates a
new root, so it is not the renewal tool. Renewing an intermediate under the
existing root needs a sign-only mode of ca-ceremony (open follow-up, plan);
until then sign by hand from `nix shell /etc/nixos#ca-ceremony-tools`
(5 y for k8s/etcd/front-proxy, 2 y for workload; one PIN + touch):

```sh
step certificate sign --template intermediate.tpl --not-after 43824h \
  --kms 'yubikey:serial=19830800?pin-source=<tmpfs file>' \
  <ca>.csr cluster/pki/root-ca.pem 'yubikey:slot-id=9c' > <ca>-ca.pem   # workload: 17520h
```

`intermediate.tpl` is the template `ceremony.sh` writes (`pathlen:0`,
`keyCertSign, cRLSign`). The pin-source file is 0600 in tmpfs, written with
`read -rs`, shredded after: without it step tries 123456 and burns a PIN
try.

## Phase 2 operations

cert-manager issues the bootstrap leaves in the cluster
([plan](pki-migration-plan.md), phase 2).

- Namespace `cluster-pki`: component `infra/cluster-pki`, applied by
  `flux-system`. It holds the export job too.
- Issuers, Certificates, policies: component `infra/cluster-pki-issuers`,
  Kustomization `cluster-pki-issuers` (deferred, like cert-manager's
  issuers).
- The leaves come from `cluster/definition.nix` through
  `k8s/components/infra/cluster-pki/leaves.nix`, by each node's roles,
  flannel-* and addon-manager-* included.

### Issuers and approver-policy

- Issuers `k8s-ca`, `etcd-ca`, `front-proxy-ca` are CA issuers over the
  Secrets of the same names in `cluster-pki`: `tls.crt` the intermediate
  (`cluster/pki/<name>.pem`), `tls.key`, `ca.crt` the root. They come from
  `k8s/secrets/cluster-pki/<name>.sops.yaml`. Without them the Issuers,
  the Certificates and `cluster-pki-issuers` are NotReady. Nothing else is
  affected.
- One Certificate per leaf, `<component>-<node>`, with a Secret of the same
  name. RSA 2048 (PKCS#1, a new key at every renewal), 8760h, renewed 720h
  before expiry. Labels `pki.neurosis/node` and `pki.neurosis/ca`, on the
  Secret too.
- The Secret's `tls.crt` is the leaf then the intermediate, for every leaf.
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
- Run it now: `kubectl -n cluster-pki create job --from=cronjob/pki-export pki-export-now`.
- Local runs: `nix run .#pki-export -- --from-dir DIR --dry-run
  --repo-dir . --out OUT` (Secret YAML files in, no cluster, no git, no
  API). `nix build .#pki-export-image` is a `docker-archive` stream:
  `./result | skopeo copy docker-archive:/dev/stdin …`. Tests: `nix build
  .#checks.x86_64-linux.pki-tools` (pytest; also in `nix flake check`).

### Export job: image

The CronJob runs the image pinned by `digest` in
`k8s/components/infra/cluster-pki/export.nix`; `digest = null;` suspends
it. `.github/workflows/pki-export-image.yml` builds the image on every PR
that touches it; on `main` it pushes `ghcr.io/charlie-horse/flake/pki-export`
(tags `<sha12>` and `main`, public: the cluster has no pull secret,
`docs/ci.md`) and prints the digest in the step summary. Move the pin in a
PR; a new image never reaches the cluster without one.

### Export job: GitHub token

The job reads Secret `cluster-pki/pki-export-github`, key `token`, from
`k8s/secrets/cluster-pki/pki-export-github.sops.yaml`. To renew it (at
most a year after creation; an admin, with the YubiKey):

1. GitHub > Settings > Developer settings > Fine-grained tokens. Resource
   owner charlie-horse, "Only select repositories": charlie-horse/flake.
   Permissions: Contents read and write, Pull requests read and write
   (Metadata read is implied). Nothing else. Expiry at most a year.
2. From the dev shell, `sops k8s/secrets/cluster-pki/pki-export-github.sops.yaml`
   and replace `stringData.token`. Never put the token on a command line;
   `sops` opens `$EDITOR`.
3. Update its row in `docs/cluster.md`, "Secrets (all of them)".
4. PR, merge. The Flux Kustomization `secrets` applies it.

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
