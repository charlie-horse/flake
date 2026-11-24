# Kubernetes: in-cluster resources (`k8s/`)

`k8s/` declares every object in the cluster that is not a NixOS service.
CI renders it to YAML, publishes it, and Flux applies it. What exists and
how it is configured: read the source. `k8s/default.nix` lists the
components; cluster values come from `cluster/definition.nix`.

Terms:

- **Flux**: controllers in the cluster that fetch the render and apply it.
- **catenix**: the [Nix library](https://github.com/charlie-horse/catenix)
  each component is written in; it turns a module into Kubernetes YAML.
- **Component**: one catenix module under `k8s/components/`, rendered to
  its own directory.
- **Render**: the YAML tree that `nix build .#k8s.manifests` builds.
- **OCI artifact**: a file bundle stored in a container registry (GHCR).
- **Kustomization**: a Flux object that applies one directory of the
  render.
- **CRD** (custom resource definition): adds a new object kind to the
  Kubernetes API.
- **Admission webhook**: a service the API server asks to accept or reject
  each object before it stores it.

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

Merging to `main` deploys:

1. `checks.yml` renders (`nix flake check`).
2. `render.yml` pushes the render as an OCI artifact, signs it with cosign
   and calls Flux's Receiver (a webhook that makes Flux fetch at once).
3. Flux applies the artifact.

Flux applies only artifacts that `render.yml` signed on `main`. It
re-applies the render on the interval in `k8s/components/flux/sync.nix`,
which reverts hand edits, and deletes what is removed from the render.
Check or force a deploy: [../cluster.md](../cluster.md)
("Changing something in the cluster").

Changing the Receiver's token (`flux-system/webhook-token`) also means
updating the GitHub secrets `FLUX_WEBHOOK_TOKEN` and `FLUX_WEBHOOK_URL`
([../ci.md](../ci.md), [secrets.md](secrets.md)).

### Deferred components

Flux dry-runs every object of a Kustomization before it applies any, so
one rejected object fails the whole apply.

Rules:

- **Put objects guarded by an admission webhook with
  `failurePolicy: Fail` (everything `cert-manager.io`) in a deferred
  component** (`deferred.modules` in `k8s/default.nix`).
- Deferred components need distinct last path elements (these name their
  Kustomizations); the render checks this.

A deferred component renders under `deferred/`, which the Kustomization
`flux-system` skips. It gets its own Kustomization
(`k8s/components/flux/stages.nix`) that runs after `flux-system` and
retries until the webhook answers. A failure there leaves the rest of the
cluster's apply alone.

## Bootstrap (fresh cluster)

Flux needs the pod network and DNS to run, so the first apply is manual.
After it, Flux owns everything in the render, itself included.

On any node ([../../CLAUDE.md](../../CLAUDE.md#access) for logging in),
use the break-glass admin kubeconfig (`/etc/kubernetes/admin.kubeconfig`,
root only; [../pki.md](../pki.md)): build as admin, run `kubectl` and
`flux` as root.

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
manual apply.

Rule: never `kubectl apply -R -f $R` on the whole tree;
`deferred/kustomization.yaml` is not a Kubernetes object.

Smoke test:

- `flux get kustomizations` shows every Kustomization Ready.
- `kubectl get clusterissuers` shows `cluster-ca` Ready.
- `kubectl get pods -A -o wide` shows the per-node apps on every node.
