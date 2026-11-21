# Cluster PKI

How to operate the cluster PKI: the YubiKey root CA, the bootstrap and
workload intermediates, and the per-node leaves that cert-manager issues
and the export job brings to the hosts as sops files. What exists is
declared in `cluster/definition.nix`, `cluster/pki/`,
`k8s/components/infra/cluster-pki/` and `modules/cluster/pki-sops.nix`. The
inventory of every secret is [secrets.md](secrets.md); how hosts decrypt
sops files is [auth.md](auth.md#sops-nix-on-the-hosts).

- [Bootstrap PKI and workload PKI](#bootstrap-pki-and-workload-pki)
- [YubiKey root CA](#yubikey-root-ca)
- [Where certs come from](#where-certs-come-from)
- [Break-glass](#break-glass)
- [Offline signing when the cluster is down](#offline-signing-when-the-cluster-is-down)
- [CA rotation](#ca-rotation)
- [In-cluster issuance](#in-cluster-issuance)

## Bootstrap PKI and workload PKI

Rules:

- **Anchor rule.** Bootstrap trust bundles (`cluster/pki/{k8s,etcd,front-proxy}-ca.pem`,
  installed as `ca.pem`, `etcd-ca.pem`, `front-proxy-ca.pem` and the
  kubelet `clientCAFile`) contain **only their own intermediate**: never
  the root, never the workload intermediate. Check a leaf by hand with
  `openssl verify -partial_chain -CAfile ca.pem <leaf>.pem`.
- Only workloads trust the root itself.
- **No CA key on a node.** Leave `clusterSigningCertFile` unset.
- **The kubelet node name must equal the short hostname** for the Node
  authorizer.
- **etcd snapshots contain the bootstrap CA keys** (the Secrets in
  `cluster-pki`): treat every snapshot as cluster-admin material.
- **Workload intermediate renewal is manual.** cert-manager does not renew
  a CA Secret it did not issue. About 60 days before `cluster/pki/workload-ca.pem`
  expires, sign a new one with the root
  ([how](#signing-an-intermediate-under-the-existing-root)) and replace
  `k8s/secrets/cert-manager/cluster-ca.sops.yaml` (PR, merge; Flux applies
  it). Leaf durations must stay under its remaining life.
- **Fresh cluster:** the binding of `system:kube-apiserver` to
  `system:kubelet-api-admin` (`k8s/components/infra/rbac.nix`) must be
  applied with the admin cert; until then `kubectl logs/exec` get 403.

## YubiKey root CA

The root key is in PIV slot **9c** of the admin YubiKey (serial 19830800),
the card that also holds the sops admin key (slot 82) and the FIDO2 key
`ssh:admin`. Every signature takes the PIN and a touch. Public material and
fingerprints: `cluster/pki/`.

- **Never run `ykman piv reset`.** It wipes every PIV slot: the root key in
  9c and the sops key in 82. The root key has no copy.
- **Never touch slot 82.**
- **PIN, PUK and management key** are shared with the sops key. The PIN is
  held by the user, offline. The PUK is in `secrets/admin.yaml`. The
  management key is PIN-protected on the card, so `ykman` asks for the PIN
  when it writes slot 9c. Never put the PIN on a command line or in shell
  history.
- **A blocked PIN** is unblocked with the PUK; while blocked the card can't
  decrypt, so read the PUK from `secrets/admin.yaml` with `admin_backup`.
- **Card lost, broken or reset:** the root is gone; re-root every
  intermediate under a new root. sops survives through `admin_backup`.
- The card travels with the user and is never parked in a host. The user
  runs every signing step.

### Tools: ca-ceremony-tools

Enter ad hoc with `nix shell <flake>#ca-ceremony-tools` (on a host:
`/etc/nixos#ca-ceremony-tools`); contents: `pkgs/ca-ceremony-tools/`. A
desktop with pcscd needs nothing else; on a server, `sudo -i`, then
`ca-pcscd &` for a temporary pcscd.

- `ca-ceremony` is the first-time root ceremony only; it refuses to run
  while slot 9c holds a key. `MODE=rehearsal` uses SoftHSM, no card.
- Sign only with `step`; don't sign with `ca-openssl`.
- The step KMS URI must carry `pin-source=<0600 tmpfs file>` (written with
  `read -rs`, shredded after); without it step tries the default PIN
  123456 and burns one of three tries.
- `ykman list` sees the key over FIDO/HID even without pcscd; check PC/SC
  with `ykman piv info`.
- Wait for ykman's "Enter PIN" prompt before typing; earlier keystrokes
  are lost.

## Where certs come from

cert-manager renews a leaf 30 days before expiry; the CronJob
`cluster-pki/pki-export` opens a PR `pki-renew/<date>` with
`secrets/pki/<node>.yaml` within a day. Merge it and switch each host
([cluster.md, Changing a host](cluster.md#changing-a-host)). If a renewal
PR sits unmerged, the export job starts failing once a cert on `main` is
within 14 days of expiry: a failed `pki-export` run is the signal.

### On the nodes: `/run/secrets/pki/`

The files, their owners and modes are declared in
`modules/cluster/pki-sops.nix`; subjects and SANs in
`k8s/components/infra/cluster-pki/leaves.nix`. To read a live leaf:
`openssl x509 -noout -subject -ext subjectAltName -in /run/secrets/pki/<leaf>.pem`.

## Break-glass

On any control-plane node, independent of authentik:

```sh
sudo kubectl --kubeconfig /etc/kubernetes/admin.kubeconfig get nodes
sudo kubectl --kubeconfig /etc/kubernetes/admin.kubeconfig -s https://127.0.0.1:6443 get nodes   # VIP down
```

The admin cert never leaves the node. People use OIDC
([k8s/apps.md](k8s/apps.md#authentik)).

## Offline signing when the cluster is down

If cert-manager can't renew a leaf, sign it with the intermediate from sops
(the only offline copy of the CA keys). On any machine with a checkout and
the YubiKey (on a server: `sudo -i`, then `ca-pcscd &`) or `admin_backup`.
Keys only in tmpfs:

```sh
nix shell /etc/nixos#ca-ceremony-tools       # step, sops, yq, openssl
t=$(mktemp -d -p /dev/shm) && cd "$t"
s=/etc/nixos/k8s/secrets/cluster-pki/k8s-ca.sops.yaml   # or etcd-ca, front-proxy-ca
sops -d "$s" | yq '.data."tls.crt"' | base64 -d > ca.pem
(umask 077; sops -d "$s" | yq '.data."tls.key"' | base64 -d > ca-key.pem)
# subject and SANs from the old cert:
#   openssl x509 -noout -subject -ext subjectAltName -in /run/secrets/pki/<leaf>.pem
openssl req -new -newkey rsa:2048 -nodes -keyout leaf-key.pem -out leaf.csr \
  -subj '/O=system:nodes/CN=system:node:r440' -addext 'subjectAltName=DNS:r440,IP:127.0.0.1,…'
step certificate sign leaf.csr ca.pem ca-key.pem --bundle --not-after 720h > leaf.pem
```

- Quick, until the next activation: copy the pair to the node and
  `sudo install` it over `/run/secrets/pki/<leaf>.pem` (`-m 0644 -o root`)
  and `-key.pem` (`-m 0600 -o <owner from pki-sops.nix>`), then restart its
  unit.
- To keep it: on a branch, write both into `secrets/pki/<node>.yaml` with
  `jq -Rs . < leaf-key.pem | sops set --value-stdin secrets/pki/<node>.yaml '["<leaf>-key.pem"]'`
  (the cert likewise), PR, merge, switch.
- `shred -u "$t"/*` when done. Once the cluster is back, the export job's
  next PR replaces the leaf.

## CA rotation

A bootstrap intermediate is replaced by a new one under the same root:
trust first, then leaves, then drop the old CA. Every switch is one host at
a time with the etcd check and `readyz` after each
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

`ca-ceremony` always creates a new root, so it is not the renewal tool.
Sign by hand from `nix shell /etc/nixos#ca-ceremony-tools` (5 y for
k8s/etcd/front-proxy, 2 y for workload; one PIN + touch):

```sh
step certificate sign --template intermediate.tpl --not-after 43824h \
  --kms 'yubikey:serial=19830800?pin-source=<tmpfs file>' \
  <ca>.csr cluster/pki/root-ca.pem 'yubikey:slot-id=9c' > <ca>-ca.pem   # workload: 17520h
```

`intermediate.tpl` is the template `ceremony.sh` writes (`pathlen:0`,
`keyCertSign, cRLSign`).

## In-cluster issuance

Issuers, Certificates, approver-policy policies and the export CronJob are
declared in `k8s/components/infra/cluster-pki/`; the leaves follow
`cluster/definition.nix`. Changing a leaf there changes its Certificate and
its policy in one render; cert-manager reissues it and the export job
brings it to the hosts.

### Export job

- Run it now: `kubectl -n cluster-pki create job --from=cronjob/pki-export pki-export-now`.
- Merging its PR is a human step.
- Local runs: `nix run .#pki-export -- --from-dir DIR --dry-run
  --repo-dir . --out OUT` (Secret YAML files in, no cluster, no git, no
  API). Tests: `nix build .#checks.x86_64-linux.pki-tools`.

### Export job: image

The CronJob runs the image pinned by `digest` in
`k8s/components/infra/cluster-pki/export.nix`; `digest = null;` suspends
it. On `main`, `.github/workflows/pki-export-image.yml` pushes the image
to GHCR and ATCR ([k8s/apps.md](k8s/apps.md#the-flakes-images-and-fluxs-source))
and prints the digest in the step summary. Move the pin in a PR; a new
image never reaches the cluster without one. Build locally with
`nix build .#pki-export-image` (a `docker-archive` stream:
`./result | skopeo copy docker-archive:/dev/stdin …`).

### Export job: GitHub token

Secret `cluster-pki/pki-export-github`, key `token`, from
`k8s/secrets/cluster-pki/pki-export-github.sops.yaml`. To renew it (at
most a year after creation; an admin, with the YubiKey):

1. GitHub > Settings > Developer settings > Fine-grained tokens. Resource
   owner charlie-horse, "Only select repositories": charlie-horse/flake.
   Permissions: Contents read and write, Pull requests read and write
   (Metadata read is implied). Nothing else. Expiry at most a year.
2. From the dev shell, `sops k8s/secrets/cluster-pki/pki-export-github.sops.yaml`
   and replace `stringData.token`. Never put the token on a command line;
   `sops` opens `$EDITOR`.
3. Update its row in [secrets.md](secrets.md).
4. PR, merge. The Flux Kustomization `secrets` applies it.
