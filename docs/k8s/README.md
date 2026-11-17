# Kubernetes: in-cluster resources (`k8s/`)

Every object in the cluster that is not a NixOS service is declared in
[`k8s/`](../../k8s) as a [catenix](https://github.com/charlie-horse/catenix)
module, rendered to a tree of YAML, published by CI as a signed OCI
artifact and applied by Flux. What exists and how it is configured: read
the source (`k8s/default.nix` is the registry; cluster values come from
`cluster/definition.nix`).

Related: [secrets.md](secrets.md) (sops-encrypted Secrets),
[apps.md](apps.md) (operating the apps), [../pki.md](../pki.md),
[../ci.md](../ci.md) (`render.yml`), [../cluster.md](../cluster.md).

## Render

```sh
nix build .#k8s.manifests                                  # -> ./result
nix eval .#k8s.components.\"apps/authentik\".config.build.manifests --json
```

Rule: never commit the render; CI builds it.

**Adding a component:** write its module under `k8s/components/` and add
one line to `components` in `k8s/default.nix` (or to `deferred.modules`,
[below](#deferred-components)). `render.nix` needs no change.

**Bumping a chart:** in `k8s/charts.nix`, change `version`, set
`hash = lib.fakeHash`, build, and copy the hash Nix reports.

## Deployment

Merging to `main` deploys: `checks.yml` renders (`nix flake check`), then
`render.yml` pushes and cosign-signs the artifact and pokes Flux's
Receiver. Flux
applies only artifacts signed by `render.yml` on `main`, re-applies every
10 minutes (reverting hand edits) and prunes what is removed from the
render. Check or force a deploy: [../cluster.md](../cluster.md)
("Changing something in the cluster").

Changing the Receiver's token (`flux-system/webhook-token`) also means
updating the GitHub secrets `FLUX_WEBHOOK_TOKEN` and `FLUX_WEBHOOK_URL`
([../ci.md](../ci.md), [secrets.md](secrets.md)).

### Deferred components

Flux dry-runs every object of a Kustomization before applying any, so one
rejected object fails the whole apply. **Put objects guarded by an
admission webhook with `failurePolicy: Fail` (everything `cert-manager.io`
and `postgresql.cnpg.io`) in a deferred component** (`deferred.modules` in `k8s/default.nix`). It
renders under `deferred/`, which the Kustomization `flux-system` skips, and
gets its own Kustomization (`k8s/components/flux/stages.nix`) that runs
after `flux-system` and retries until the webhook answers. A failure there
leaves the rest of the cluster's apply alone. Deferred components need
distinct last path elements (their Kustomization names); the render
asserts it.

## Bootstrap (fresh cluster)

Flux can't run before the pod network and DNS, so the first apply is
manual; afterwards Flux owns everything in the render, itself included.
Use the break-glass admin kubeconfig on any node
(`/etc/kubernetes/admin.kubeconfig`, root only; [../pki.md](../pki.md)):
build as admin, run `kubectl` and `flux` as root.

```sh
nix build .#k8s.manifests && R=./result
kubectl apply --server-side -R -f $R/infra/
kubectl apply --server-side -f $R/flux/00-namespaces.yaml -f $R/flux/01-customresourcedefinitions.yaml
kubectl wait --for condition=established --timeout=60s \
  crd/ocirepositories.source.toolkit.fluxcd.io \
  crd/kustomizations.kustomize.toolkit.fluxcd.io \
  crd/receivers.notification.toolkit.fluxcd.io
kubectl apply --server-side -R -f $R/flux/
flux get kustomizations --watch   # or: kubectl -n flux-system get ks
```

Then create `flux-system/sops-age`
([secrets.md](secrets.md#the-bootstrap-key-flux-systemsops-age)) so the
Kustomization `secrets` can decrypt. The apps and `deferred/` need no
manual apply. Never `kubectl apply -R -f $R` on the whole tree:
`deferred/kustomization.yaml` is not a Kubernetes object.

Smoke test: `flux get kustomizations` shows every Kustomization Ready,
`kubectl get clusterissuers` shows `cluster-ca` Ready, and
`kubectl get pods -A -o wide` shows the per-node apps on every node.
