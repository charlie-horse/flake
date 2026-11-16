# neurosis cluster: operations

The cluster is declared in `cluster/definition.nix` (nodes, roles,
addresses) and `modules/cluster/` (host side); everything inside it is
`k8s/`, deployed by Flux ([k8s/README.md](k8s/README.md)). Read those, not
this doc, for what runs where. Every secret: [secrets.md](secrets.md).

## Changing a host

1. Branch → PR → CI (`checks.yml`, [ci.md](ci.md)) → merge.
2. On the host, as admin:
   `cd /etc/nixos && git pull && sudo nixos-rebuild switch --flake /etc/nixos#<host>`
   (m2mini adds `--override-input m2mini-vendorfw path:/boot/vendorfw`).
3. One host at a time; after each, `systemctl --failed` (`switch` exiting
   with status 4 means a unit failed) and the etcd check below. Never take
   two etcd members down together.
4. c4130: GC first (`sudo nix-env -p /nix/var/nix/profiles/system --delete-generations +2 && sudo nix-collect-garbage`;
   [hosts/c4130.md](hosts/c4130.md)).

Never edit files in `/etc/nixos` or run `nix flake update` on a host, and
never `sudo git` there (root-owned files break the next pull until a switch
or boot re-owns the tree). Builds happen on r440 ([build-cache.md](build-cache.md)).

### etcd health check (any member, in bash)

```sh
D=/run/secrets/pki; n=$(hostname); C=$D/etcd-server-$n
E="sudo etcdctl --endpoints=https://r440:2379,https://c4130:2379,https://m2mini:2379 \
   --cacert=$D/etcd-ca.pem --cert=$C.pem --key=$C-key.pem"
$E endpoint health --cluster -w table     # 3 x true
$E endpoint status --cluster -w table     # 1 leader, raft index moving
$E member list -w table                   # r440/c4130/m2mini, unchanged
sudo journalctl -u etcd --since -5min | grep -iE 'x509|tls|handshake'   # empty
```

`snapshot save` takes exactly one endpoint: use `--endpoints=https://$n:2379`.

## Changing something in the cluster

1. Edit `k8s/` (or `cluster/definition.nix`), branch → PR. `checks.yml`
   renders the PR's commit (`nix flake check`).
2. Merge. Once `checks.yml` passes on `main`, `render.yml` pushes the
   render to GHCR as a cosign-signed OCI artifact and pings Flux's
   webhook; Flux applies it within seconds
   ([ci.md](ci.md), [k8s/README.md](k8s/README.md)).

Check or force it, with your OIDC kubeconfig or, on a node, the
break-glass one ([Kubernetes API access](#kubernetes-api-access)):

```sh
F="nix shell nixpkgs#fluxcd -c flux"                                # OIDC
F="sudo $(nix build --no-link --print-out-paths nixpkgs#fluxcd)/bin/flux --kubeconfig /etc/kubernetes/admin.kubeconfig"   # break-glass
$F get sources oci                    # Ready, SourceVerified
$F reconcile kustomization flux-system --with-source
$F get kustomizations                 # all Ready
```

## Kubernetes API access

- **Break-glass:** on any node,
  `sudo kubectl --kubeconfig /etc/kubernetes/admin.kubeconfig …`
  ([pki.md](pki.md#break-glass)).
- **People:** OIDC through authentik, kubectl with kubelogin or Headlamp
  ([k8s/apps.md](k8s/apps.md)).
- **kubeconfig server:** the keepalived VIP on the LAN or the Tailscale
  Service from the tailnet (`vip`, `apiserverTailscaleService` and `domain`
  in `cluster/definition.nix`), e.g.
  `kubectl config set-cluster neurosis --server=https://kube-api.leaffish-monster.ts.net:6443`.

## Tailscale

The servers' Tailscale prefs are declared in `modules/server/tailscale.nix`
and `server.tailscale.*` per host. Rules:

- Never turn `ssh` off: Tailscale SSH is the only way into the hosts, and
  from a session that came in over it, that locks everyone out.
- The flags must match the live prefs (`tailscale debug prefs`) exactly,
  including `advertiseTags`; `tailscale set` only touches the prefs it
  names, so a mismatch silently changes routing or SSH at the next switch.
- A hand-made `tailscale set` is undone by the next boot or switch: change
  the Nix instead.

**Reinstall:** generate a pre-approved, non-ephemeral auth key tagged
`tag:node` in the admin console. On the new host, as root (never in git,
the store or a command line):

```sh
sudo install -d -m 0700 /var/lib/tailscale
sudo sh -c 'umask 077; cat > /var/lib/tailscale/authkey'   # paste, ^D
```

Switch, then delete the file once the node shows up. Without the file
`tailscaled-autoconnect` is skipped.

### Tailscale Service for the API (`svc:kube-api`)

Declared in `modules/cluster/tailscale-service.nix`. The node advertises it
unapproved until this admin-console setup (once per tailnet) is done:

1. Services → Advertise → Define a Service: name `kube-api`, endpoint
   `tcp:6443`, description "neurosis Kubernetes API".
2. Policy file: approve tag:node hosts automatically and let the admins
   reach it (adjust `src` to who should use kubectl):

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

Clients ≥ 1.94 need no `--accept-routes` (older Linux clients do). A
running but unready apiserver still gets traffic (no `/readyz` check).

Check (read-only), on a node and from a client:

```sh
tailscale serve status --json        # Services."svc:kube-api".TCP."6443"
tailscale debug prefs | jq .AdvertiseServices   # ["svc:kube-api"]
kubectl --server=https://kube-api.leaffish-monster.ts.net:6443 get --raw /readyz
```

After a change to `apiserverExtraSANs`, cert-manager reissues the
`apiserver-<node>` Certificates; run the export job
([pki.md](pki.md#export-job)), merge its PR and switch the hosts. Check each
with `curl -skf https://127.0.0.1:6443/readyz` (`-f`: a not-ready apiserver
still answers, with HTTP 500).
