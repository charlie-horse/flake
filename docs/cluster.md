# neurosis cluster: operations

Procedures for the Kubernetes cluster the servers form. The nodes and
their roles are in `cluster/definition.nix`, the host side in
`modules/cluster/`, and everything inside the cluster in `k8s/`, which Flux
(the in-cluster tool that applies the rendered manifests) deploys
([k8s/README.md](k8s/README.md)). Every secret: [secrets.md](secrets.md).
Getting onto a host: [CLAUDE.md](../CLAUDE.md#access).

## Changing a host

1. Branch → PR → CI ([ci.md](ci.md)) → merge.
2. On the host, as admin:
   `cd /etc/nixos && git pull && sudo nixos-rebuild switch --flake /etc/nixos#<host>`.
   c4130 and m2mini have their own deploy steps:
   [hosts/c4130.md](hosts/c4130.md#deploying-c4130),
   [hosts/m2mini.md](hosts/m2mini.md#deploy).
3. Switch one host at a time. After each, read `systemctl --failed`
   (`switch` exits with status 4 when a unit failed) and run the etcd check
   below. Never take two etcd members down together.

Rules for `/etc/nixos` (no edits, no `nix flake update`, no git as root):
[CLAUDE.md](../CLAUDE.md#access). If a root-run git left root-owned files
there, a switch or reboot gives the tree back to admin. Builds run on the
remote builder ([build-cache.md](build-cache.md)).

### etcd health check (any member, in bash)

etcd is the database that stores the cluster state; each node with the
`etcd` role runs one member.

```sh
D=/run/secrets/pki; n=$(hostname); C=$D/etcd-server-$n
E="sudo etcdctl --endpoints=https://$n:2379 \
   --cacert=$D/etcd-ca.pem --cert=$C.pem --key=$C-key.pem"
$E endpoint health --cluster -w table     # every member true
$E endpoint status --cluster -w table     # 1 leader, raft index moving
$E member list -w table                   # the etcd nodes of cluster/definition.nix
sudo journalctl -u etcd --since -5min | grep -iE 'x509|tls|handshake'   # empty
```

`$E snapshot save <file>` works as is: it takes exactly one endpoint.

## Changing something in the cluster

1. Edit `k8s/` (or `cluster/definition.nix`) on a branch and open a PR. CI
   renders it as part of `nix flake check`.
2. Merge. CI on `main` publishes the render and Flux applies it
   ([ci.md](ci.md#renderyml), [k8s/README.md](k8s/README.md#deployment)).

Check or force it with your OIDC kubeconfig or, on a node, the break-glass
one ([Kubernetes API access](#kubernetes-api-access)):

```sh
F="nix shell nixpkgs#fluxcd -c flux"                                # OIDC
F="sudo $(nix build --no-link --print-out-paths nixpkgs#fluxcd)/bin/flux --kubeconfig /etc/kubernetes/admin.kubeconfig"   # break-glass
$F get sources oci                    # Ready, SourceVerified
$F reconcile kustomization flux-system --with-source
$F get kustomizations                 # all Ready
```

## Kubernetes API access

A kubeconfig is the file that tells `kubectl` which API server to use and
how to log in.

- **Break-glass** (admin access that works without the login service): on
  any node, `sudo kubectl --kubeconfig /etc/kubernetes/admin.kubeconfig …`
  ([pki.md](pki.md#break-glass)).
- **People:** OIDC (single sign-on) through authentik, with kubectl and
  kubelogin, or Headlamp ([k8s/apps.md](k8s/apps.md)).
- **kubeconfig server:** on the LAN, the API's virtual IP (`vip`); from the
  tailnet, the Tailscale Service
  `https://<apiserverTailscaleService>.<domain>:<apiserverPort>`. All values
  are in `cluster/definition.nix`. Set it with
  `kubectl config set-cluster <name> --server=<url>`.

## Tailscale

The servers' Tailscale settings are in `modules/server/tailscale.nix` and
`server.tailscale.*` per host. Rules:

- Never set `ssh` to false: it locks everyone out of the hosts.
- Keep the flags equal to the live prefs (`tailscale debug prefs`),
  `advertiseTags` included. A mismatch changes routing or SSH at the next
  switch.
- A hand-made `tailscale set` is undone by the next boot or switch: change
  the Nix instead.

**Reinstall:** in the Tailscale admin console, generate an auth key that is
pre-approved, non-ephemeral and tagged `tag:node`. On the new host (never
put the key in git, the Nix store or a command line):

```sh
sudo install -d -m 0700 /var/lib/tailscale
sudo sh -c 'umask 077; cat > /var/lib/tailscale/authkey'   # paste, ^D
```

Switch, then delete the file once the node shows up. Without the file,
`tailscaled-autoconnect` does nothing.

### Tailscale Service for the API (`svc:kube-api`)

A Tailscale Service is one tailnet name that forwards to every host that
advertises it. Declared in `modules/cluster/tailscale-service.nix`. The
nodes advertise it, unapproved, until this admin-console setup is done
(once per tailnet):

1. Services → Advertise → Define a Service: name `kube-api`, endpoint
   `tcp:6443`, description "neurosis Kubernetes API".
2. Policy file: approve tag:node hosts automatically and let the admins
   reach it (set `src` to who may use kubectl):

   ```jsonc
   "tagOwners": {
     "tag:node": ["autogroup:admin"],
   },
   "autoApprovers": {
     "services": {
       "svc:kube-api": ["tag:node"],
     },
   },
   "grants": [
     { "src": ["autogroup:admin"], "dst": ["svc:kube-api"], "ip": ["tcp:6443"] },
   ],
   ```

   Without `autoApprovers`, approve each host by hand on the service's page
   (Service hosts → Approve).

Linux clients older than Tailscale 1.94 need `--accept-routes` to reach it.
The Service also sends traffic to an apiserver that runs but is not ready.

Check (read-only), on a node and from a client:

```sh
tailscale serve status --json        # Services."svc:kube-api".TCP."6443"
tailscale debug prefs | jq .AdvertiseServices   # ["svc:kube-api"]
kubectl --server=https://kube-api.<domain>:6443 get --raw /readyz
```

After a change to `apiserverExtraSANs`, cert-manager (the in-cluster
certificate issuer) reissues the `apiserver-<node>` Certificates. Run the
export job ([pki.md](pki.md#export-job)), merge its PR and switch the hosts.
Check each with `curl -skf https://127.0.0.1:6443/readyz` (`-f` makes curl
fail on the HTTP 500 a not-ready apiserver returns).
