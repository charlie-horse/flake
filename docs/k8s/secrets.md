# Kubernetes Secrets (sops in git)

Every Kubernetes Secret the cluster's workloads need is a sops-encrypted
manifest in git, `k8s/secrets/<namespace>/<name>.sops.yaml`, decrypted in
the cluster by kustomize-controller. Not in git: the Secrets the cluster
makes itself (the cert-manager webhook's own CA, the leaves cert-manager
issues) and the one bootstrap secret, `flux-system/sops-age`
([below](#the-bootstrap-key-flux-systemsops-age)).

The inventory of every secret, in and out of the cluster, is
[../secrets.md](../secrets.md); add a row there for any new one. Overview
of the render and Flux: [README.md](README.md).

Who reads a Secret: grep its name in `k8s/components/`.

## How they are rendered and applied

- **Render.** `render.nix` (`checkSecret`) checks each file and copies it
  byte for byte. A file must be one v1 Secret whose
  `metadata.namespace`/`name` match its path, with every
  `data`/`stringData` value encrypted and **keys sorted**; anything else in
  `k8s/secrets/` fails the render.
- **Allowed top-level keys:** `apiVersion kind metadata type data
  stringData sops`, nothing else. The render (`checkSecret` in
  `render.nix`) and the `sops` flake check (`scripts/check-sops.py`,
  [../ci.md](../ci.md)) check the same set;
  change both together. The first four stay in the clear (kustomize and
  Flux read them), `data`/`stringData` are encrypted. No `immutable` (Flux
  could not apply a rotation).
- **Apply.** The Kustomization `secrets` (`k8s/components/flux/secrets.nix`)
  decrypts them with `flux-system/sops-age`. Like the
  [deferred components](README.md#deferred-components), a missing key, a
  file encrypted to the wrong key or a broken MAC fails only `secrets`.
- **Flux owns these Secrets.** Git is the only place to change them; a
  hand edit in the cluster is reverted at the next reconcile.
- **Prune** (`prune: true`): deleting a `.sops.yaml` file deletes its
  Secret from the cluster once that commit is applied, and the pods that
  read it fail at their next start (`CreateContainerConfigError`). Removing
  the last file removes the Kustomization `secrets` itself and with it
  every Secret it applied. To hand a Secret back to manual care instead,
  first merge the annotation `kustomize.toolkit.fluxcd.io/prune: disabled`
  in its `metadata` (sops leaves metadata unencrypted), let it apply, then
  delete the file.

## Changing a value (rotation)

On a machine with an admin sops identity (the YubiKey or the backup key;
[../secrets.md](../secrets.md)) and a checkout of this repo, on a branch,
with `nix shell nixpkgs#sops nixpkgs#jq nixpkgs#yq-go nixpkgs#openssl`
(plus `nixpkgs#age-plugin-yubikey` for the YubiKey):

1. Edit the file: `sops k8s/secrets/<namespace>/<name>.sops.yaml` opens it
   decrypted in `$EDITOR` and re-encrypts on save. Values under `data` are
   base64 of the exact bytes (`printf %s "$v" | base64 -w0`; no trailing
   newline); values under `stringData` (`pki-export-github`) are
   plain text. Keep the keys sorted ([below](#sorted-keys)). To replace one
   `data` value without an editor, and without the value on a command line:

   ```sh
   f=k8s/secrets/<namespace>/<name>.sops.yaml
   # generated: (a new random value)
   openssl rand -hex 32 | tr -d '\n' | base64 -w0 | jq -R . \
     | sops set --value-stdin "$f" '["data"]["<KEY>"]'
   # or typed / pasted:
   read -rs v && printf %s "$v" | base64 -w0 | jq -R . \
     | sops set --value-stdin "$f" '["data"]["<KEY>"]'; unset v
   ```

   (`sops set` keeps an existing key in place but appends a new one at the
   end: add keys with `sops "$f"`, in sorted position.)
2. PR. CI renders it (sorted keys, path, encryption) and runs the secrets
   guard. Merge.
3. `render.yml` publishes and Flux applies it within seconds; to force or
   check it (OIDC, or the break-glass kubeconfig on a node,
   [../pki.md](../pki.md)):
   `flux reconcile kustomization secrets --with-source`, then
   `flux get kustomizations secrets` (Ready, the new revision).
4. Restart what reads it: environment variables and files
   are read at start, so running pods keep the old value until then:
   `kubectl -n <namespace> rollout restart deploy/<name>`.

Some values can't simply be replaced: `AUTHENTIK_SECRET_KEY` never,
`AUTHENTIK_POSTGRESQL__PASSWORD` only together with the database
([apps.md](apps.md#the-secret-authentikauthentik-secrets)), the webhook
token only with its GitHub secrets ([README.md](README.md#deployment)),
the CA Secrets only by a new signature from the root ([../pki.md](../pki.md)).

## Adding one

1. Write the Secret (template below), keys sorted, and encrypt it to
   `k8s/secrets/<namespace>/<name>.sops.yaml`. The namespace must be one
   the render creates. From a live Secret, without writing plaintext to
   disk:

   ```sh
   f=k8s/secrets/<namespace>/<name>.sops.yaml
   kubectl -n <namespace> get secret <name> -o yaml \
     | yq '.metadata |= {"name": .name, "namespace": .namespace} | sort_keys(..)' \
     | sops encrypt --filename-override "$f" --input-type yaml --output-type yaml /dev/stdin > "$f.tmp" \
     && mv "$f.tmp" "$f"
   ```

   For a new one, `sops "$f"` on a file that doesn't exist yet opens an
   editor and encrypts what you type.
2. Point the workload at it (`secretKeyRef` / a `secret` volume) and add a
   row to [../secrets.md](../secrets.md).
3. PR, merge. A Secret that already existed (made by hand) is adopted by
   the first apply (server-side apply, forced ownership), not recreated;
   from then on it is Flux's.

Template (before encryption; keys sorted, `data` base64 of the exact bytes,
so no stray trailing newline):

```yaml
apiVersion: v1
data:
  KEY: <base64>
kind: Secret
metadata:
  name: <name>
  namespace: <namespace>
type: Opaque
```

### Sorted keys

A file whose keys were not sorted when it was encrypted fails in the
cluster with "MAC mismatch" (kustomize sorts keys before decrypting), so
the render refuses it. To fix one:
`sops decrypt "$f" | yq 'sort_keys(..)'` piped into the `sops encrypt` line
above.

## The bootstrap key (flux-system/sops-age)

Flux's age private key, recipient `&flux` in `/.sops.yaml`. It
exists only in the cluster (and so in etcd and its backups); never in git,
never on disk, never copied out. Until it exists the Kustomization
`secrets` is not Ready and the Secrets keep their last applied values (on a
fresh cluster: none, so the apps wait in `CreateContainerConfigError`).

On a fresh cluster, after the [Bootstrap](README.md#bootstrap-fresh-cluster),
make a new one as root on a node:

```sh
sudo -i
export KUBECONFIG=/etc/kubernetes/admin.kubeconfig   # break-glass (docs/pki.md)
nix shell nixpkgs#age nixpkgs#kubectl -c bash -ec '
  age-keygen 2>/dev/null \
    | kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=/dev/stdin
  kubectl -n flux-system get secret sops-age -o jsonpath="{.data.age\.agekey}" \
    | base64 -d | age-keygen -y'   # prints the new recipient
```

(The key name must end in `.agekey`.) Then re-wrap every file for the new
recipient: on a branch, set `&flux` in `/.sops.yaml` to the printed
recipient, run `sops updatekeys -y <file>` for each
`k8s/secrets/*/*.sops.yaml` with an admin identity, PR, merge. The values are unchanged; only the
wrapped data key is new. The same applies if the Secret is ever lost or
deleted on a running cluster. Never re-create it with a different key
without re-wrapping: `secrets` would fail on every file.
