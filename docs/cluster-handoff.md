# Cluster hand-off: solaris (c4130, r440, m2mini)

Status on 2026-10-31, branch `claude/cluster`. Nothing here has been
switched on a live host yet. Every step below is run by a person with sudo.

> **Order.** This whole runbook comes **after** Ada's r440 → c4130
> vLLM/builder switches, which run from Ada's standalone flakes
> (`~/flint-nix/builder/etc-nixos{,-c4130}`). Before step 2, re-sync
> `hosts/c4130` and `hosts/r440` from Ada's final copies and re-check parity
> against the **live** systems (see "Before you start").

- [What exists](#what-exists)
- [Defaults chosen and open questions](#defaults-chosen-and-open-questions)
- [Secrets that must be rotated](#secrets-that-must-be-rotated)
- [Before you start](#before-you-start)
- [Switch order](#switch-order) (steps 0–6)
- [TODO (minor findings)](#todo-minor-findings)

## What exists

| Path | What |
|---|---|
| `cluster/definition.nix` | Pure data: CIDRs (pods `10.244.0.0/16`, services `10.96.0.0/12`, DNS `10.96.0.10`), VIP `10.0.0.200`, and per node: IPs, roles, `gpu`, `cri`, keepalived priority, labels/taints, `kubeletConfig`, and **`rollout`** (`stage`, `etcdPhase`), which says where the node is in this runbook. |
| `lib/system/mkServer.nix` | Server builder: host dir + `modules/cluster` only (no desktop, home-manager or agenix). Famine/Pestilence/Death/Miniserver/War still use `mkHost`. |
| `hosts/{c4130,r440,m2mini}` | Ports of the hosts' own flakes (c4130/r440 from Ada's copies). Their old `k8s.nix` and `tls/` are not carried over. |
| `modules/cluster/` | Manual `services.kubernetes` (no easyCerts): etcd (same member names and peer URLs), apiserver `Node,RBAC`, controller-manager, scheduler, kubelet, kube-proxy, containerd (`nvidia` handler on c4130), keepalived on all 3 nodes, firewall. Secrets are **string** paths under `/var/lib/kubernetes/secrets`. |
| `pkgs/cluster-pki` | `cluster-pki` (CAs, leaves, rotation) and `cluster-pki-deploy` (stages a node's files over ssh and prints the `sudo install` lines). See [pki.md](pki.md). |
| `k8s/` | catenix modules → `k8s/rendered/`: RuntimeClasses, RBAC (`05-rbac`: apiserver → kubelet API), flannel, CoreDNS, NVIDIA device plugin, Flux (public HTTPS GitRepository, no secret), podinfo. See [k8s/README.md](../k8s/README.md). |
| `.github/workflows/k8s.yml` | Secrets guard, host evals with IFD off, render check. See [ci.md](ci.md). |

### Rollout knobs (new in this commit)

Per node in `cluster/definition.nix` (`rollout = { stage; etcdPhase; }`),
which feed the module options `clusterNode.stage` and
`clusterNode.etcd.phase`:

| `stage` | Runs |
|---|---|
| `"etcd"` | etcd + firewall only. No apiserver, no keepalived, no kubelet/runtime. `net.ipv4.ip_forward = 1` is kept. |
| `"controlPlane"` | + kube-apiserver, controller-manager, scheduler (controlPlane nodes) and keepalived (+ HAProxy on m2mini). |
| `"full"` | + kubelet, kube-proxy, containerd (end state). |

| `etcdPhase` | etcd presents | etcd trusts | peerClientCertAuth | apiserver → etcd client cert |
|---|---|---|---|---|
| `"trust"` | legacy leaf, copied to `legacy-etcd-peer-<n>{,-key}.pem` | `etcd-ca.pem` (new + legacy CA) | off (as today) | `legacy-etcd-client-apiserver-<n>` |
| `"final"` | `etcd-server-<n>` / `etcd-peer-<n>` | `etcd-ca.pem` | on | `etcd-client-apiserver-<n>` |

**Committed state: every node `stage = "etcd"`, `etcdPhase = "trust"`.**
That is the first thing step 2 switches to, so switching the committed config
can never hit the hard-cut-over failure (a member presenting a new-CA leaf
to members that only trust `ETCD CA 1`). The end state (`full`/`final`) was
evaluated too: r440 and m2mini give exactly the toplevels of the previous
commit (`22lbqxbh…`, `459b2dax…`); c4130 differs from it only in the r440
cache key and the kubelet eviction config (both intended).

## Defaults chosen and open questions

Defaults I chose (change them in `cluster/definition.nix` or the module):

1. **etcd switch order r440 → m2mini → c4130** (as the coordinator asked).
   r440 is the current leader, so its restart causes one election. Optional:
   `etcdctl move-leader <id of m2mini>` first.
2. **Stopgap SAN `192.0.0.1`** on every apiserver leaf
   (`apiserverExtraSANs`), because etcd still holds the `kubernetes` Service
   at the legacy IP until step 3d. Drop it after step 3d and re-issue.
3. **c4130 kubelet eviction** is absolute (`nodefs/imagefs.available<5Gi`,
   image GC at 98/97 %), because `/` is 96 % full (17 GB free of 366 GB).
   With upstream defaults c4130 would sit in DiskPressure. The real fix is
   freeing space or moving `/var/lib/containerd` + `/var/lib/kubernetes`.
4. **NVIDIA device plugin `deviceIDStrategy = index`**, to match the CDI
   spec NixOS generates on c4130 (`device-name-strategy = "index"`). The host
   is unchanged.
5. **No deploy key** for Flux: the GitRepository is public HTTPS
   (`https://github.com/charlie-horse/flake`, user decision). A key is only
   needed if the repo goes private (see step 5).

Open questions (decide before the step named):

- **Decided: GPUs vs production vLLM.** The device plugin stays, but c4130
  registers with the taint `nvidia.com/gpu=vllm:NoSchedule`
  (`cluster/definition.nix`, `nodes.c4130.taints`), so only pods that
  tolerate it land there (the device plugin and flannel do). To opt a pod
  in (only while vLLM is stopped; the V100s aren't shareable):
  ```yaml
  spec:
    runtimeClassName: nvidia
    tolerations:
      - { key: nvidia.com/gpu, operator: Equal, value: vllm, effect: NoSchedule }
    containers:
      - resources: { limits: { nvidia.com/gpu: 1 } }
  ```
- **Decided: tailnet exposure on c4130.** `tailscale0` is NOT trusted on
  c4130 (`nodes.c4130.trustTailscale = false`): only its cluster ports for
  the active stage (2379/2380; plus 6443, 10250 and 8472/udp at the full
  stage) are opened there, next to the host's own 8000/8081/8082. r440 and
  m2mini keep `tailscale0` trusted (default `trustTailscale = true`).
- **Before step 2 (m2mini): `/etc/containers`.** On m2mini, cri-o implicitly
  enabled `virtualisation.containers`; the new config drops
  `/etc/containers/{containers.conf,policy.json,registries.conf,storage.conf}`
  there. If anyone runs podman on m2mini, add
  `virtualisation.containers.enable = true` to `hosts/m2mini` (as r440 does).
  (r440 is covered: its four files are byte-identical store paths before and
  after; charlie's podman uses its own GC-rooted
  `podman-5.8.6` with its own crun/runc/conmon.)
- **Before step 3: keepalived.** The LVS `virtual_server` (SSL_GET /readyz)
  is gone; the VIP holder serves 6443 itself and a local `/readyz`
  `vrrp_script` decides who holds it. The old c4130 keepalived speaks
  multicast with instance `api-frontend`, the new ones unicast with
  `apiserver`; they don't see each other. That is why keepalived is off in
  stage `etcd`: by the time any node runs the new keepalived (step 3), c4130's
  old one is gone. No VRRP auth (there was none before either).

## Secrets that must be rotated

These are human actions; the repo can only stop making it worse.

1. **charlie's login/sudo password (m2mini, Miniserver, and wherever else it
   is reused, e.g. c4130/r440).** The plaintext that was in m2mini's
   `/etc/nixos/m2mini.nix` is byte-identical to the one committed in
   `hosts/Miniserver/default.nix` since 9a37de5, which is on `main` of the
   **public** repo. It is compromised. This commit removes it from the tree
   (Miniserver now uses `custom.user.passwordFile =
   "/var/lib/secrets/charlie.passwd"`; with `mutableUsers = true` that
   changes nothing on the running box), but it stays in git history.
   On each host: `passwd` (choose a NEW password), then write the hash file
   for future installs:
   `mkpasswd -m yescrypt | sudo install -D -m 0600 /dev/stdin /var/lib/secrets/charlie.passwd`.
   Purging history (`git filter-repo` + force-push) is optional; rotation is
   what matters.
2. **Every legacy cluster key** (in `/nix/store` on all 3 hosts): replaced by
   the new PKI, deleted from the store in step 6.
3. **Pestilence `rpc-password`** (`hosts/Pestilence/servarr.nix`): see TODO.

## Before you start

On the operator machine (a trusted machine with this flake checked out;
not a node):

```sh
git -C ~/src/flake pull                     # branch claude/cluster or main
# Re-sync from Ada's final copies (they were still changing on 2026-10-31):
mkdir -p /tmp/ada/c4130 /tmp/ada/r440
ssh c4130 'tar -C ~/flint-nix/builder/etc-nixos-c4130 -cf - --exclude=tls --exclude="*.kubeconfig" .' | tar -xf - -C /tmp/ada/c4130
ssh r440  'tar -C ~/flint-nix/builder/etc-nixos       -cf - --exclude=tls --exclude="*.kubeconfig" .' | tar -xf - -C /tmp/ada/r440
diff -r /tmp/ada/c4130 hosts/c4130; diff -r /tmp/ada/r440 hosts/r440
# Expected differences from Ada's copies: only the cluster-port and
# ip_forward lines in configuration.nix (c4130, r440) and r440's
# firewall.nix/builder.nix comments (cluster ports moved to modules/cluster).
```

Parity against the **live** systems (not the old targets): on each host,

```sh
live=$(nix-store -q --deriver "$(readlink -f /run/current-system)")
new=$(nix eval --raw ~/src/flake#nixosConfigurations.$(hostname).config.system.build.toplevel.drvPath)
# m2mini: add --override-input m2mini-vendorfw path:/boot/vendorfw
nix run nixpkgs#nix-diff -- "$live" "$new"
```

Expect differences only in etcd, the kube-* units, keepalived, cri-o (gone),
firewall, users, sysctl/modules. Nothing in `nix.conf`, vLLM/LMCache,
harmonia, bond0 or nixremote. Measured on 2026-10-31 for the committed
state: c4130 vs `kqf7s007…`, r440 vs `z14bn097…`, m2mini vs `c5qh6rz1…`:
exactly that.

Build each host before switching it (on m2mini, or let c4130 use r440 as
remote builder; **no CUDA rebuilds**: c4130's vLLM closure is already in its
store and must come out identical):

```sh
nixos-rebuild build --flake ~/src/flake#<host>     # as charlie, no sudo
nix store diff-closures /run/current-system ./result
```

Common health check (used below; run on any etcd member, `bash`, not fish):

```sh
D=/var/lib/kubernetes/secrets; n=$(hostname)
# "trust" phase:  C=$D/legacy-etcd-peer-$n     "final" phase:  C=$D/etcd-server-$n
E="sudo etcdctl --endpoints=https://r440:2379,https://c4130:2379,https://m2mini:2379 \
   --cacert=$D/etcd-ca.pem --cert=$C.pem --key=$C-key.pem"
$E endpoint health --cluster -w table     # 3 x true
$E endpoint status --cluster -w table     # 1 leader, raft index moving
$E member list -w table                   # r440/c4130/m2mini, https://<n>:2380, unchanged
sudo journalctl -u etcd --since -5min | grep -iE 'x509|tls|handshake'   # empty
```

Never continue to the next member unless all three are healthy. If a step
fails, roll back **that member only**; the other two hold quorum.

**c4130 serving:** `vllm.service` requires `vllm-lmcache.service`, so any
switch that changes the LMCache unit (its args, `l1SizeGb`/`l2SizeGb`,
environment or package) restarts LMCache (L1 emptied) and vllm with it:
~3 min without the API (165 s on 2026-10-31). Check with
`nix store diff-closures /run/current-system ./result | grep -i lmcache`
before switching c4130, and schedule such switches like a vLLM restart.

## Switch order

### Step 0: generate the PKI (operator machine)

Keep the output **outside** any flake or git checkout (a `path:` evaluation
or a non-git copy would copy the keys into `/nix/store`):

```sh
PKI=~/.local/share/cluster-pki/solaris
nix run ~/src/flake#cluster-pki -- --out $PKI
scp r440:/etc/nixos/tls/ca/etcd.pem /tmp/legacy-etcd-ca.pem      # PUBLIC cert
openssl x509 -noout -subject -in /tmp/legacy-etcd-ca.pem         # CN = ETCD CA 1
nix run ~/src/flake#cluster-pki -- --out $PKI --trust etcd /tmp/legacy-etcd-ca.pem
```

Verify: `nix run ~/src/flake#cluster-pki -- --out $PKI status` shows every
leaf `ok`, the etcd bundle lists the new CA **and** `CN=ETCD CA 1`, and
`openssl x509 -noout -ext subjectAltName -in $PKI/apiserver-r440.pem` lists
`10.96.0.1`, `10.0.0.200` and the stopgap `192.0.0.1`. Back `$PKI` up,
encrypted and offline.

Rollback: nothing is deployed yet; `rm -rf $PKI`.

### Step 1: deploy the certs to `/var/lib/kubernetes/secrets` (each node)

Nothing restarts in this step; the running services keep using their
legacy store paths.

```sh
for n in r440 m2mini c4130; do
  nix run ~/src/flake#cluster-pki-deploy -- $n --out $PKI   # stages ~/cluster-pki-staging/$n
done
```

On each node, `ssh -t <node> bash`, paste the printed `sudo install …`
lines and `rm -rf "$S"`. **Do not run the printed `systemctl restart`
lines now.** Then copy the legacy etcd member cert out of the store into the
secrets dir (legacy keys are already exposed, so this adds no exposure; they
are deleted in step 2c):

```sh
D=/var/lib/kubernetes/secrets; n=$(hostname)
cert=$(systemctl show etcd -p Environment | tr ' ' '\n' | sed -n 's/^ETCD_CERT_FILE=//p')
key=$(systemctl show etcd -p Environment | tr ' ' '\n' | sed -n 's/^ETCD_KEY_FILE=//p')
echo "$cert $key"     # two /nix/store/...-etcd.pem / -etcd-key.pem paths
sudo install -m 0644 -o root -g root "$cert" $D/legacy-etcd-peer-$n.pem
sudo install -m 0600 -o etcd -g etcd "$key"  $D/legacy-etcd-peer-$n-key.pem
```

(`legacy-etcd-client-apiserver-<n>` is only needed if you run step 3 before
step 2b; this order doesn't.)

Verify on each node:

```sh
sudo ls -l $D        # keys 0600 owned by etcd/kubernetes/root, certs 0644
openssl verify -partial_chain -CAfile $D/etcd-ca.pem $D/legacy-etcd-peer-$n.pem   # OK
openssl verify -CAfile $D/etcd-ca.pem $D/etcd-server-$n.pem                       # OK
```

Rollback: `sudo rm -rf /var/lib/kubernetes/secrets` (nothing uses it yet).

### Step 2: etcd, member by member (r440, then m2mini, then c4130)

Before the first member: snapshot on a healthy member (safety net only):
`$E snapshot save /var/lib/etcd-snap-$(date +%F).db` (with `C` = the legacy
cert path, as above, and `sudo`).

**2a. Trust phase** (committed config: `stage = "etcd"`,
`etcdPhase = "trust"`). For each of r440, m2mini, c4130, one at a time:

```sh
sudo nixos-rebuild switch --flake ~/src/flake#<host>   # m2mini: + --override-input m2mini-vendorfw path:/boot/vendorfw
# then the health check with C=$D/legacy-etcd-peer-$n
```

What changes on the host: etcd now reads its cert from the secrets dir
(same legacy leaf) and trusts the bundle; the old apiserver, controller
manager, scheduler, kubelet, cri-o and the old keepalived of that host
stop (the API is down from c4130's switch until step 3; the cluster runs no
workloads). On r440 check charlie's podman afterwards:
`ps -ef | grep '[p]odman'` still lists the SWE-bench service, and
`readlink -f /etc/static/containers/*` is unchanged.
`switch` can exit 4 if a unit failed; read `systemctl --failed`.

Rollback (that member only): `sudo nixos-rebuild switch --rollback`, then
the health check. The data dir is never touched.

**2b. Final phase**, only when all three run `"trust"`: set
`rollout.etcdPhase = "final"` for **one** node in
`cluster/definition.nix`, switch it, health check with
`C=$D/etcd-server-$n`; then the next. Same order. A final member trusts
both CAs and accepts the legacy leaves of the others; they trust the bundle
and accept its new leaf. `peerClientCertAuth` turns on per member.

Rollback: set that node back to `"trust"` and switch (or `--rollback`).

**2c. Drop the legacy etcd CA**, only when all three run `"final"`:

```sh
nix run ~/src/flake#cluster-pki -- --out $PKI --rotate-ca etcd --phase finish
nix run ~/src/flake#cluster-pki -- --out $PKI status   # etcd bundle: new CA only
```

Then per node, one at a time: `cluster-pki-deploy <n> --out $PKI`, install
only `etcd-ca.pem` from the printed lines, `sudo systemctl restart etcd`,
health check, then `sudo rm -f $D/legacy-*`. Confirm every
`ETCD_*FILE` points into the secrets dir:
`systemctl show etcd -p Environment | tr ' ' '\n' | grep FILE=` (no
`/nix/store` and no `legacy-`).

Rollback: re-trust the legacy CA
(`cluster-pki --trust etcd $PKI/ca/etcd/retired/<ts>/trust/*.pem`), redeploy
the bundle node by node.

### Step 3: control plane (r440, then c4130)

**3a.** Set `rollout.stage = "controlPlane"` for r440, switch, then c4130.

Verify on each:

```sh
systemctl is-active etcd kube-apiserver kube-controller-manager kube-scheduler keepalived
curl -sk https://127.0.0.1:6443/readyz; echo        # ok
ip -4 addr show eno1 | grep 10.0.0.200              # on c4130 once it is up (prio 150)
```

**3b.** Admin kubeconfig, on the operator machine only (never on a node,
never in git):

```sh
K=$PKI/admin.kubeconfig
kubectl config set-cluster solaris --server=https://10.0.0.200:6443 \
  --certificate-authority=$PKI/ca.pem --embed-certs --kubeconfig=$K
kubectl config set-credentials admin --client-certificate=$PKI/admin-r440.pem \
  --client-key=$PKI/admin-r440-key.pem --embed-certs --kubeconfig=$K
kubectl config set-context solaris --cluster=solaris --user=admin --kubeconfig=$K
kubectl config use-context solaris --kubeconfig=$K
export KUBECONFIG=$K
kubectl get --raw '/readyz?verbose' | tail -1       # readyz check passed
kubectl auth can-i '*' '*'                          # yes
```

**3c.** RBAC that NixOS's (disabled) addon manager would have created:

```sh
kubectl apply --server-side -f k8s/rendered/00-runtime-classes.yaml -f k8s/rendered/05-rbac.yaml
kubectl get clusterrolebinding system:kube-apiserver:kubelet-api-admin
```

**3d. Service-CIDR cut-over** (192.0.0.0/24 → 10.96.0.0/12). The old
`kubernetes` ServiceCIDR and the `default/kubernetes` Service at
`192.0.0.1` are still in etcd; ClusterIP is immutable and the apiserver only
reconciles the Service's ports.

```sh
kubectl get servicecidr                       # 'kubernetes' 192.0.0.0/24
kubectl get svc -A -o wide                    # every ClusterIP still in 192.0.0.0/24
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: ServiceCIDR
metadata:
  name: solaris-services
spec:
  cidrs: ["10.96.0.0/12"]
EOF
kubectl delete servicecidr kubernetes --wait=false
kubectl -n default delete svc kubernetes      # recreated by the apiserver
# delete (and later re-apply) every other Service still in 192.0.0.0/24
sleep 15
kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}'; echo   # 10.96.0.1
kubectl get servicecidr                       # old one gone; 'kubernetes' is
                                              # 10.96.0.0/12 again once recreated
kubectl get ipaddresses | grep -c '^192\.0\.0\.'                    # 0
# Nodes registered by the legacy kubelets keep their immutable podCIDR:
kubectl get nodes -o custom-columns=NAME:.metadata.name,CIDR:.spec.podCIDR
kubectl delete node <every node whose podCIDR is not in 10.244.0.0/16>
```

When `kubectl get servicecidr kubernetes` shows `10.96.0.0/12`,
`kubectl delete servicecidr solaris-services`.

Fallback if the ServiceCIDR stays stuck in Terminating: the cluster has no
workloads, so wipe the registry. Stop `kube-apiserver
kube-controller-manager kube-scheduler` on r440 and c4130, run
`$E del /registry --prefix` once, start them again, and redo 3c.

After 3d: remove `apiserverExtraSANs = [ "192.0.0.1" ]` from the
definition, `cluster-pki --out $PKI` (re-issues `apiserver-*`), deploy to
r440/c4130, `sudo systemctl restart kube-apiserver` one at a time.

Rollback (3a–3d): set the node back to `stage = "etcd"` and switch. etcd is
unaffected.

### Step 4: kubelet / kube-proxy (r440, c4130, m2mini; one at a time)

Set `rollout.stage = "full"` for the node and switch. On c4130 first check
`free -g` (vLLM + LMCache hold ~110 GB; keep MemAvailable > 12 GB) and
`df -h /var/lib` (≥ 10 GB free; images need ~1–2 GB).

Verify:

```sh
systemctl is-active containerd kubelet kube-proxy      # (m2mini also: keepalived haproxy)
kubectl get nodes -o wide                              # node registered, NotReady until flannel
kubectl get node c4130 -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.present}'   # true
kubectl describe node c4130 | grep -E 'DiskPressure|Taints'       # False, nvidia.com/gpu=vllm:NoSchedule
```

r440 again: charlie's podman still running, `/etc/containers` unchanged.

Then the pod network and DNS (still manual; Flux needs them):

```sh
kubectl apply --server-side -f k8s/rendered/10-flannel.yaml -f k8s/rendered/20-coredns.yaml
kubectl get nodes                                      # all Ready
kubectl -n kube-system get pods -o wide                # flannel x3, coredns x2 Running
kubectl run dnstest --rm -it --restart=Never --image=busybox:1.37 -- \
  nslookup github.com                                  # external DNS from a pod
kubectl logs -n kube-system -l app.kubernetes.io/name=coredns --tail=1   # logs work (05-rbac)
```

If external DNS fails from pods, CoreDNS's `forward . /etc/resolv.conf`
(MagicDNS 100.100.100.100) is the cause; forward to `10.0.0.1` instead.

Rollback: set the node back to `stage = "controlPlane"` and switch.

### Step 5: Flux bootstrap

Decide the GPU question above first: Flux applies **everything** in
`k8s/rendered/`, including the device plugin. Flux reads branch `main`, so
merge (and let CI render) first.

```sh
kubectl apply --server-side -f k8s/rendered/40-flux-system.yaml
kubectl wait --for condition=established --timeout=60s \
  crd/gitrepositories.source.toolkit.fluxcd.io crd/kustomizations.kustomize.toolkit.fluxcd.io
kubectl apply --server-side -f k8s/rendered/50-flux-sync.yaml
kubectl -n flux-system get gitrepository,kustomization   # Ready=True, revision main@sha1:…
kubectl -n podinfo get pods -o wide                       # one per node, incl. m2mini (arm64)
```

Deploy key: **none** while the repo is public (user decision: public HTTPS,
no `secretRef`). If it goes private: create a read-only deploy key on
GitHub, `flux create secret git flux-system --url=ssh://git@github.com/charlie-horse/flake --private-key-file=<key>`,
switch the GitRepository URL to `ssh://…` with `secretRef.name: flux-system`
in `k8s/components/flux-sync.nix`, re-render, merge. The key never goes in
git.

GPU smoke test (only once the GPU policy is decided and vLLM headroom is
confirmed): a CUDA pod with `runtimeClassName: nvidia` and
`nvidia.com/gpu: 1` should start and `nvidia-smi -L` should list one GPU.

Rollback: suspend, don't delete (deleting a pruning Kustomization deletes
what it manages):
`kubectl -n flux-system patch kustomization flux-system --type=merge -p '{"spec":{"suspend":true}}'`.

### Step 6: remove old generations and GC the leaked keys

Only when all three nodes run the new PKI, step 2c is done, and nobody
needs to roll back past it (give it a few days). Per host:

```sh
sudo nix-env -p /nix/var/nix/profiles/system --delete-generations +2   # keep current + 1
sudo nix-collect-garbage                     # removes the unreferenced store paths
sudo /run/current-system/bin/switch-to-configuration boot   # refresh boot entries
sudo find /nix/store -maxdepth 1 -name '*-key.pem' | wc -l  # 0 (names only; never cat them)
```

- `nix-collect-garbage -d` would also delete user profiles' old
  generations; the `--delete-generations` form only touches the system.
- r440: charlie's `~/flint-swebench/podman-pkg` is a GC root, so podman and
  its runtimes stay. Don't touch it while the SWE-bench run is going.
- c4130: GC also drops old vLLM builds; the current one is rooted. Do it
  after Ada's switches have settled, never while one is pending.
- m2mini: this also removes the old generation that carries the plaintext
  password (`users-groups.json`).

Then delete the legacy sources (the old flakes are not in git):
`sudo rm -rf /etc/nixos/tls` (c4130, r440) and `/etc/nixos/mod/tls`
(m2mini), and rotate the password (see above).

Verify: `nix-store -qR /run/current-system | grep -c -- '-key.pem$'` is 0
on every host.

## TODO (minor findings)

Done in this commit: `cluster-pki-deploy` no longer prints a non-existent
`flannel` unit; `docs/pki.md` no longer claims a `flannel-client` binding.

- [ ] **Pestilence `rpc-password`** (`hosts/Pestilence/servarr.nix:35`) is
      plaintext in the public repo: rotate it, move it to agenix (the age
      module exists for Pestilence).
- [ ] **CI secrets guard** (`.github/workflows/k8s.yml`): run it on every
      path (no `paths:` filter), match `(initial)?(hashed)?password` case-
      insensitively and crypt prefixes `$y$ $6$ $2b$ $7$`, flag `kind: Secret`
      with data/stringData and `token:` lines, don't skip comments for key/
      crypt patterns, don't exempt `*.nix`/`*.md` from the filename check.
- [ ] **cluster-pki default `--out`** is `./pki-out`: default to
      `${XDG_DATA_HOME:-~/.local/share}/cluster-pki` and refuse an `--out`
      under a dir with `flake.nix`/`.git` (this runbook already passes
      `--out`). Update `docs/pki.md:11`.
- [ ] **.gitignore**: add `kubeconfig*`, `*.kubeconfig.yaml`, `admin.conf`,
      `*.p12`, `*.pfx`, `*.passwd`, `cluster-pki-staging/`, `secrets/`.
- [ ] **Unused leaves**: drop `flannel-<n>` and `addon-manager-<n>` from
      `SPECS`, and keep `admin-<n>` (a `system:masters` key) off the nodes
      (no `node_files` entry). Fix `docs/pki.md` table lines 107–111.
- [ ] **CA subject** `<name> <ca> CA <date>` is not unique within a day: add
      time/serial, or print SKI + fingerprint in `status`.
- [ ] **Leaf expiry** (1 year, no renewal automation): calendar a re-issue
      30 days before expiry, or add an expiry check to CI/monitoring.
- [ ] **keepalived**: document the LVS removal (done above), optionally
      add `auth_pass`.
- [ ] **c4130 GPU taint** / device plugin opt-in (see open questions).
- [ ] **`runtimeConfig = "api/all=true"`** (control-plane.nix): enables
      every alpha/beta API on 1.36. Drop it or list what is needed.
- [ ] **CoreDNS upstream**: smoke-test external DNS from a pod (step 4);
      otherwise forward to `10.0.0.1` and keep MagicDNS for `ts.net` only.
- [ ] **`initialClusterState = "new"`**: ignored while `/var/lib/etcd`
      exists; flip to `"existing"` before re-creating a member's data dir.
- [ ] **m2mini 16 KiB pages**: label it (e.g.
      `node.kubernetes.io/page-size=16k` in `labels`) and note it in
      `k8s/README.md`; 4K-page arm64 images (jemalloc) can crash there.
- [ ] **Parity targets**: use the live derivers (r440 `z14bn097…`, c4130
      `kqf7s007…`, m2mini `c5qh6rz1…`), not `s0sgd…`/`z8hx…`.
- [ ] **Action SHAs**: confirm on github.com that actions/checkout
      `3d3c42e5` = v7.0.1, cachix/install-nix-action `448cde73` = v31.11.2,
      upload-artifact `cf430e03` = v7.0.2, download-artifact `9000827c` =
      v8.0.2.
- [ ] **c4130 disk**: free space on `/` or move `/var/lib/containerd` and
      `/var/lib/kubernetes` to a bigger filesystem; then relax the
      thresholds in `cluster/definition.nix`.
- [ ] **War** (`darwinConfigurations.War`) fails to evaluate with
      `attribute 'nixos' missing`, also at base 9a37de5 (pre-existing, not
      touched here).
