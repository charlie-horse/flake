# Cilium Gateway API for solaris: research and recommendation

Date: 2026-11-10. Scope: web research plus reading this repo (HEAD `38ff56f`).
Nothing was run on any host. Upstream versions are as of today: **Cilium
1.20.4** (current stable, 2026-10-23), Gateway API v1.6.3, Envoy Gateway
v1.10.0, NGINX Gateway Fabric v2.8.1, Traefik v3.7.18.

Tags used throughout:
- **[V]**: verified in upstream docs, upstream source at a release tag, an
  upstream issue, or this repo.
- **[I]**: inferred from those sources and not tested.

## TL;DR: recommendation

**Don't adopt Cilium now just to get Gateway API ingress.** On this cluster
Cilium's Gateway costs a full CNI swap plus kube-proxy replacement on three
live nodes, one of which runs production vLLM and an etcd member. It also
fails on the one hard requirement, authentik's client IP, without help.
Concretely:

1. **Kube-proxy replacement is required.** Cilium's Gateway needs
   `kubeProxyReplacement=true` [V]. You cannot keep kube-proxy and only swap
   the CNI.
2. **Cilium's Envoy can't overwrite X-Forwarded-For from `Cf-Connecting-Ip`
   cleanly.** It always appends, and a CiliumEnvoyConfig can't patch the
   Gateway listener [V]. authentik would still need the r440 nginx in front.
3. **Two high-severity node risks are open upstream.** cilium-envoy (tcmalloc,
   48-bit VA assumption) probably aborts on m2mini's 16K/47-bit-VA Asahi
   kernel [I, mechanism V]. Host Tailscale also collides with Cilium's packet
   marks and `src_valid_mark` handling [V, open issues].
4. **The NixOS kubelet module fights Cilium's CNI install.** It keeps
   `/etc/cni/net.d` read-only in the store and wipes `/opt/cni/bin/*` on every
   kubelet start [V]. Both can be solved, but only with custom Nix plumbing
   and no prior art.

**Do this instead (Plan A):**
1. Keep flannel and kube-proxy.
2. Add **Envoy Gateway** (Helm chart pinned in `k8s/charts.nix`, a catenix
   component) with its Envoy pinned to the amd64 nodes, behind a fixed
   ClusterIP.
3. Point the existing **host cloudflared on r440** at it for new apps.
4. Leave **authentik on its current path** (host cloudflared → loopback nginx
   → ClusterIP 10.96.0.20) because the apiserver's OIDC depends on it.

This is a few PRs, causes no node downtime, and rolls back with a Flux revert.

**Revisit Cilium (Plan B, below) only as its own CNI project**, if you
later want NetworkPolicy enforcement, Hubble or eBPF service load balancing
for their own sake. It is gated on the m2mini and Tailscale checks in step B0.

---

## 1. Prerequisites for Cilium Gateway API (1.20.4)

| Requirement | Value | Status |
|---|---|---|
| CNI | Cilium must be the CNI | [V] |
| kube-proxy | `kubeProxyReplacement=true` is required for Gateway API | [V] [gw] |
| Gateway API CRDs | Minimum v1.6.1; the docs install v1.6.3. Required: GatewayClass, Gateway, HTTPRoute, GRPCRoute, BackendTLSPolicy, ReferenceGrant, TLSRoute (`v1` must be served). Optional: TCPRoute/UDPRoute/ListenerSet (features turn off if absent) | [V] [gw] [upg] |
| L7 proxy | `l7Proxy=true` (default). Envoy runs as the separate `cilium-envoy` DaemonSet (`envoy.enabled` defaults true on new installs) | [V] [helm] [envoy] |
| TPROXY | With the default `bpf.tproxy=false`, nodes need the iptables TPROXY modules, or Gateway connections time out | [V] [gw] |
| Enable | `gatewayAPI.enabled=true` | [V] [helm] |
| Host network mode | `gatewayAPI.hostNetwork.enabled=true` plus `hostNetwork.nodes.matchLabels`. Mutually exclusive with LB-Service mode. Envoy binds `0.0.0.0:<listener port>` on the selected nodes | [V] [gw] |
| Ports below 1024 | Need `envoy.securityContext.capabilities.keepCapNetBindService=true` plus `NET_BIND_SERVICE`; or use a port above 1023 | [V] [gw] |
| XFF knobs | `gatewayAPI.useRemoteAddress` (default true), `gatewayAPI.xffNumTrustedHops` (default 0), `gatewayAPI.enableProxyProtocol` (all-or-nothing per Gateway listener) | [V] [helm] |
| BTF | Effectively required in 1.20. SNAT program load fails without BTF (cilium#47718), and 1.20.2 broke socket-LB without BTF (cilium#48778) | [V] |
| Kubernetes | 1.20 is e2e-tested on 1.33–1.36, so v1.36.3 is covered | [V] [compat] |

Cilium's Gateway limitations that matter here:
- **One Envoy per node serves every Gateway, Ingress and L7 policy on that
  node** [V] [envoy].
- **No client-traffic policy CRD.** The only per-client knobs are the global
  Helm keys above [I].
- **The docs warn of "limited user feedback"** for some Gateway features
  [V] [gw].

### Exposure without a cloud LB

| Mode | Fit for "only client is cloudflared on r440" | Notes |
|---|---|---|
| **hostNetwork** pinned to r440 | **Best** | Deterministic. cloudflared → `127.0.0.1:<port>`. No ARP or leases. Envoy binds every interface (including tailscale0), so firewall the port [V/I] |
| NodePort on the generated LB Service | OK | The Service stays `<pending>` but has a ClusterIP and NodePorts. The ports are random and the ClusterIP isn't pinnable through the Gateway [I] |
| LB-IPAM without L2 announcements | OK | Pool IP reachable from the node's host namespace via KPR [I]; test it |
| LB-IPAM plus **L2 announcements** | Avoid | Needs KPR and a raised `k8sClientRateLimit` (default 5 qps/10 burst is "quickly reached"). Failover takes 10–20 s. One node takes all traffic for an IP. Not compatible with `externalTrafficPolicy: Local` [V] [l2]. A second ARP speaker on the LAN next to keepalived's VIP 10.0.0.200 adds risk for no benefit [I] |
| BGP | No | No BGP router on the LAN [I] |

## 2. Migrating flannel + kube-proxy to Cilium on the live cluster

### 2.1 The upstream path [V] [mig]

The official "Migrating a cluster to Cilium" guide runs both overlays side
by side.

**Requirements:**
- A **new pod CIDR** (cluster-pool IPAM), for example `10.245.0.0/16`.
- A **different VXLAN port** (`tunnelPort=8473`).
- An old CNI that uses the Linux routing stack. Flannel is explicitly
  supported.

**Migration values:**
- `cni.customConf=true`, `cni.uninstall=false`
- `policyEnforcementMode=never`
- `bpf.hostLegacyRouting=true`. This is what routes traffic between the two
  overlays.
- `operator.unmanagedPodWatcher.restart=false`

**Per node, one at a time:**
1. Cordon and drain.
2. Label the node `io.cilium.migration/cilium-default=true`. A
   `CiliumNodeConfig` then makes that node's agent write
   `05-cilium.conflist`.
3. Delete that node's Cilium pod.
4. Reboot.
5. Verify, then uncordon.

**Final step:**
1. Set `customConf=false`, `policyEnforcementMode=default` and
   `unmanagedPodWatcher.restart=true`.
2. Delete the CiliumNodeConfig.
3. Remove flannel.

**What the guide does and doesn't cover:**
- Pods get new IPs. ClusterIPs (10.96.0.10, 10.96.0.20) don't change [V/I].
- Flannel and Cilium pods reach each other across nodes during the
  migration [V].
- **The guide does not cover kubeProxyReplacement.** Do KPR as a separate,
  later step [I].
- Policy enforcement must stay off until the end. The three Flux
  NetworkPolicies in `k8s/rendered/40-flux-system.yaml` are unenforced on
  flannel today and **become enforced** at the final step [V repo].

### 2.2 kube-proxy → KPR [V] [kpr]

- **Pre-set the apiserver address.** Set `k8sServiceHost=10.0.0.200` and
  `k8sServicePort=6443` from the first install, so Cilium never depends on
  kube-proxy to reach 10.96.0.1. The docs say "control-plane IP"; using the
  keepalived VIP, which is already `services.kubernetes.apiserverAddress`,
  is inferred [I].
- **Switching a running node breaks its existing Service connections once.**
  The two NAT tables don't know about each other [V].
- **Cleanup:**
  1. Set `services.kubernetes.proxy.enable = false` (`modules/cluster/node.nix`).
  2. Remove the rules with `iptables-save | grep -v KUBE | iptables-restore`,
     or reboot. NixOS re-creates only its own chains [V/I].
- **Socket-LB covers host processes through cgroup-v2 root hooks.** So
  cloudflared/nginx on r440 → 10.96.0.20:80 keeps working, apart from one
  connection reset at cutover [I].
- **vLLM is unaffected.** It listens on host :8000 and uses no ClusterIPs.
  `bpf_host` on eno1 will sit in its ingress path [I].
- **`socketLB.hostNamespaceOnly` is not needed** here [V].

### 2.3 What changes on the NixOS side

| Area | Change | Status |
|---|---|---|
| `/etc/cni/net.d` | The NixOS kubelet sets `environment.etc."cni/net.d".source` to a store directory (`node.nix` `cni.configDir`), so it is read-only. Cilium's `write-cni-conf-when-ready` and `cni-exclusive` renaming can't work there. **Use instead:** keep `cni.customConf=true`, skip the label/CiliumNodeConfig step, and ship `05-cilium.conflist` from Nix per node (new `nodes.<n>.cni = "flannel" \| "cilium"` field in `cluster/definition.nix`). containerd picks the lexically first conflist | [V] (kubelet.nix, containerd) / design [I] |
| `/opt/cni/bin` | kubelet `preStart` runs `rm /opt/cni/bin/*` and relinks `cni.packages`. A kubelet restart would delete Cilium's copied `cilium-cni` until the agent restarts, and pod creation would fail meanwhile. **Fix:** package `cilium-cni` in Nix (a fixed-output derivation extracted from the pinned image), add it to `kubelet.cni.packages`, and set `cni.install=false`. Alternative: use a separate `cni.binPath` added to containerd `bin_dirs` (test the v2-config conversion) | [V] / fix [I] |
| kube-proxy | `services.kubernetes.proxy.enable = false`, in the KPR step only | [V] |
| flannel | `services.kubernetes.flannel.enable` is already false. Remove `k8s/components/flannel.nix` and `10-flannel.conflist` only after every node is on Cilium | [V repo] |
| bpffs, cgroup v2 | The chart auto-mounts both (`bpf.autoMount`, `cgroup.autoMount`). systemd already mounts `/sys/fs/bpf`, and 26.05 is unified cgroup v2. Verify with `mount` | [V]/[I] |
| sysctls | Set `sysctlfix.enabled=false`; it writes into `/etc/sysctl.d` and has open bugs (#21916, #48936). Set `rp_filter` in Nix instead | [V] |
| Reverse-path filter | The NixOS firewall defaults to `checkReversePath = true` (strict, `nixos-fw-rpfilter`). Set it to `"loose"`, because Cilium returns pod traffic via `cilium_host` | [V] default / [I] effect |
| Firewall (`modules/cluster/firewall.nix`) | From node IPs, add: udp 8473 (migration overlay), tcp 4240 plus ICMP (health), tcp 4244 (Hubble, on by default). Also add the new pod CIDR to the pod→apiserver/kubelet rule. Keep 8472 until flannel is gone | [V] ports / [I] |
| Kernel | ≥5.10 with BPF, BTF, VXLAN and IP_SET. The nixpkgs 6.18 and Asahi 7.1 builds should have them; check `/sys/kernel/btf/vmlinux` on every node, m2mini especially | [V] req / [I] config |
| Pod CIDR | After migration, set `cluster.podCidr` (controller-manager `--cluster-cidr`, firewall) to the new CIDR | [I] |
| keepalived VIP | No direct interaction as long as Cilium doesn't do L2 announcements. Keep `devices` explicit so Cilium doesn't touch VRRP | [I] |

Prior art: NixOS + Cilium write-ups are scarce. The one public repo found
doesn't handle the CNI paths. nixpkgs#53601 (Calico on the NixOS kubelet) is
still open [V].

### 2.4 Rollback and downtime

| Stage | Downtime | Rollback |
|---|---|---|
| Cilium installed, no node switched | None | `helm uninstall` (Flux revert) [I] |
| Per-node switch | That node's pods restart and get new IPs. vLLM (systemd) is untouched | Set the node back to `cni = "flannel"` (or roll back the generation) and recycle its pods [I] |
| Finalize (remove flannel) | Brief per-node blip if you set `hostLegacyRouting=false`, so leave it on | Reinstall flannel and its conflists, which is expensive [I] |
| KPR | One break of existing Service connections per node, including an auth.neuros.is blip on r440 | `proxy.enable=true`, `kubeProxyReplacement=false`, which drops connections once more [V/I] |

On c4130, skip the guide's reboot:
1. GC old generations.
2. Switch.
3. Delete the pods still on flannel.
4. Remove `cni0`/`flannel.1` later.
5. Run the etcd health check.

## 3. Node compatibility risks

| Risk | Severity | Mitigation | Status |
|---|---|---|---|
| **cilium-envoy on m2mini.** It is built with Google tcmalloc, which assumes 48-bit VA on aarch64 and aborts with `MmapAligned() failed` on smaller VA (google/tcmalloc#82, envoyproxy/envoy#17854, cilium/proxy#1027, all open). 16K-page arm64 kernels default to **47-bit VA**. The issue is VA width, not page size as such | **High** | Check `zcat /proc/config.gz \| grep -E 'VA_BITS\|PGTABLE_LEVELS'` and run the pinned cilium-envoy image once on m2mini. If it fails: keep Envoy off m2mini (affinity) and set `enable-l7-proxy=false` there via CiliumNodeConfig. Then m2mini can't serve Gateway traffic or L7 policy | Mechanism [V]; applies to the Asahi 7.1 kernel [I] |
| **Tailscale 1.98.0–1.98.3 sets `src_valid_mark=1`** on every start, which makes Cilium's L7/DNS proxy drop traffic (`IP_LOCAL_SOURCE`, cilium#48706; suspected in cilium#47940 Gateway 503s) | **High** | Pin Tailscale to 1.96, or reset the sysctl in tailscaled `ExecStartPost`, or set `accept_local=1` on `lxc*`. Check `tailscale version` | [V] (tailscale#19796 open) |
| **Tailscale fwmarks 0x40000/0x80000 overlap Cilium identity marks.** Envoy upstream traffic (ingress identity 0x80b00) is black-holed (cilium#36104, #46422, open) | High in native routing / Medium in tunnel mode | Stay in tunnel mode. Workaround: `ip rule add priority 5205 fwmark 0x80b00/0xfff000 lookup 52` | [V] / tunnel exposure [I] |
| **BPF auto-attached to `tailscale0`.** Re-attaching drops in-flight traffic (cilium#48695) | Medium | Set `devices` explicitly: `eno1` on c4130/r440, `end0` on m2mini. Don't expose NodePort/LB Services to tailnet clients: same-node reverse DNAT fails on unmanaged interfaces (cilium#49587) | [V] |
| Kernel 7.x datapath regressions (cilium#49943 on 7.0; 7.1 untested anywhere) | Medium | Soak-test on m2mini first; stay on ≥1.20.4 | [V] 7.0 / [I] 7.1 |
| Missing BTF (m2mini) | High if missing | `ls /sys/kernel/btf/vmlinux` | [I] |
| c4130 GPU: device plugin, `runtimeClassName: nvidia` | Low | No interaction found: CNI is set up per sandbox, independent of the runtime handler. The agent and Envoy default tolerations (`operator: Exists`) cover the `nvidia.com/gpu=vllm` taint | [I] / [V] tolerations |
| c4130 host vLLM :8000, LMCache 8080/8081, Open WebUI 8082 | Low | Keep `hostFirewall.enabled=false` (default). KPR's bind protection only covers the NodePort range (30000–32767) | [V] [kpr] |

## 4. Client IP for authentik

### What Cilium's Gateway does [V, Cilium 1.20.4 source]

- **The Gateway's connection manager (HCM) always appends.** It sets
  `use_remote_address: true` and `skip_xff_append: false`
  (`operator/pkg/model/translation/envoy_http_connection_manager.go`).
  `xffNumTrustedHops` only controls which entry Envoy itself treats as the
  client; it never replaces the header.
- **Gateway API header modifiers take static strings only.**
  `HTTPHeader.Value` is a plain string, so there is no "copy from another
  header" in the spec.
- **A `set` lands in Envoy verbatim.** Cilium translates a
  RequestHeaderModifier `set` into route-level `request_headers_to_add`
  (`OVERWRITE_IF_EXISTS_OR_ADD`) without escaping `%`. Envoy evaluates
  `%REQ(...)%` formatters in custom headers [V, Envoy docs]. So
  `set: X-Forwarded-For: "%REQ(cf-connecting-ip)%"` would **probably** work,
  because the router applies it after the HCM append [I, untested].
  - It works only because Cilium doesn't escape `%`. That is an
    implementation quirk, and a future release could silently turn it into
    a literal string.
- **CiliumEnvoyConfig can't patch the Gateway's listener.** It only defines
  its own listeners. Envoy's `custom_header` original-IP detection can't be
  combined with `use_remote_address`, and it doesn't rewrite the upstream
  header anyway [V].

**Verdict: Cilium can't do this cleanly.** A clean setup keeps the r440
nginx in front:
1. nginx *sets* `X-Forwarded-For = Cf-Connecting-Ip`.
2. Cilium's Envoy appends nginx's address, so authentik receives
   `<client>, <r440>`.
3. authentik reads the leftmost entry, which is correct [I].

### What authentik would see and trust [V]

- **Which entry authentik reads.** authentik (Rust server
  `ak-axum/src/extract/client_ip.rs`, and the Python fallback) takes the
  **leftmost** X-Forwarded-For entry. It does so only if the TCP peer is in
  `AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS`. It ignores X-Real-IP.
- **The peer behind Cilium's Envoy is the node's ingress IP.** That is a
  per-node address allocated from the node's pod CIDR (`CiliumNode
  .spec.ingress.ipv4`, identity `reserved:ingress`). It is not configurable
  and can change on restart.
- **How to set the trusted CIDRs if authentik sits behind a Cilium Gateway:**
  trust the pod CIDR **only together with** a CiliumNetworkPolicy. The policy
  should allow authentik-server :9000 only `fromEntities: [ingress, health,
  host]`. Without the policy, any pod could forge the header.
- **The trusted list breaks with any Cilium migration, with or without a
  Gateway.** The current `10.244.0.1/32` entry is flannel's `cni0` address,
  which is the source after kube-proxy masquerade. Under Cilium the
  host→pod source becomes r440's `cilium_host` router IP, from the new pod
  CIDR [I]. Update `AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS` in the same
  change that moves r440.

### Who can do it without the nginx front

| Gateway | How it overwrites X-Forwarded-For from `Cf-Connecting-Ip` |
|---|---|
| Envoy Gateway | `ClientTrafficPolicy.clientIPDetection.customHeader {name: Cf-Connecting-Ip, failClosed: true}` for detection, plus `headers.earlyRequestHeaders` `Set X-Forwarded-For: "%REQ(Cf-Connecting-Ip)%"`. These are documented fields; runtime behaviour is [I] |
| NGINX Gateway Fabric | Per-route `set X-Forwarded-For: $http_cf_connecting_ip`. The validator accepts it [V], runtime is [I]. A route that misses it falls back to appending |
| Cloudflare | A Request Header Transform Rule at the edge [I] |

All of these are only safe if **nothing but cloudflared can reach the
gateway**, because `Cf-Connecting-Ip` is just a header [I].

## 5. cloudflared placement

**Keep host cloudflared on r440. Don't move it in-cluster** [I, reasoning
from repo facts V]:
- **An in-cluster tunnel creates a circular dependency.** kube-apiserver's
  OIDC issuer is `https://auth.neuros.is/...` (`cluster/definition.nix`,
  `control-plane.nix`). With an in-cluster tunnel, a broken CNI, Gateway or
  Flux takes down the tunnel, OIDC logins fail, and recovery falls back to
  the break-glass x509 admin cert. That cert still works, but recovery is
  worse.
- **The host path has fewer dependencies.** Today it depends only on systemd
  on r440 and the authentik pod.
- **Keep the tunnel locally managed.** Its ingress rules live in Nix, in git.
  A remote-managed tunnel would move routing to the dashboard.
- **For new apps:** add ingress rules to a host cloudflared (a separate
  tunnel and credential per trust domain, as `solaris-auth` does) that point
  at the Gateway.
- **For HA:** run a second host-level connector for the same tunnel on
  another node. Cloudflare supports several connectors per tunnel [V]
  [cf-ha]. Install the credential out of band, root-only under
  `/var/lib/secrets`, as today.
- **If you ever run cloudflared in-cluster:** the tunnel credential goes in a
  hand-created Secret or SOPS, never in git. Keep `auth.` on a host tunnel
  regardless.

## 6. Alternatives on top of flannel (comparison only)

| Option | Version | Gateway API | Client IP from `Cf-Connecting-Ip` | Exposure without LB | arm64 / 16K | Notes |
|---|---|---|---|---|---|---|
| **Envoy Gateway** | v1.10.0 (Envoy 1.40) [V] | v1.6.1, Conformant [V] | Built-in detection (`customHeader`, `failClosed`) plus an early `Set` of X-Forwarded-For [V fields / I runtime] | `envoyService.type` ClusterIP/NodePort; DaemonSet; `patch` for hostNetwork/clusterIP [V] | Same tcmalloc risk as cilium-envoy, so pin to amd64 [V/I] | Chart `oci://docker.io/envoyproxy/gateway-helm` [V] |
| NGINX Gateway Fabric | v2.8.1 [V] | v1.6.3, Conformant [V] | No custom-header mode (`rewriteClientIP` is ProxyProtocol/XFF only). Per-route `set` works [V/I] | NginxProxy ClusterIP/NodePort, DaemonSet [V] | No allocator risk [I] | Every route must carry the set |
| Traefik | v3.7.18 [V] | v1.6.3, Conformant [V] | Needs a third-party plugin (cloudflarewarp) [V] | NodePort/hostNetwork [I] | Go, fine [I] | Plugin supply chain |
| ingress-nginx | **retired** | — | — | — | — | Best-effort maintenance ended March 2026; no further releases or security fixes [V] [ingnx] |
| Cilium Gateway | 1.20.4 | v1.6.1+, Conformant [V] | Append only; `%REQ()%` quirk [V/I] | hostNetwork/LB-IPAM [V] | Same tcmalloc risk [I] | Requires CNI swap plus KPR |

## 7. Recommendation and staged plan

### Plan A (recommended): Envoy Gateway on flannel

Each step is one PR (branch → CI → merge → Flux), unless it says otherwise.
None of these steps touches c4130's host config or etcd.

**A1. Gateway API CRDs v1.6.3, standard channel.**
- Change: a catenix component, vendored and hash-pinned.
- Verify: `kubectl get crd gateways.gateway.networking.k8s.io`.
- Rollback: Flux revert. Nothing uses the CRDs yet.

**A2. Envoy Gateway controller.**
- Change: pin `envoy-gateway` in `k8s/charts.nix` and add
  `k8s/components/envoy-gateway.nix`.
- Pin the controller and the Envoy pods with `nodeSelector:
  kubernetes.io/arch: amd64`. This avoids the m2mini tcmalloc risk. In
  practice they land on r440, since c4130 is tainted and Envoy shouldn't
  tolerate it.
- Verify: the controller is Ready and the `GatewayClass` is Accepted.
- Rollback: Flux revert.

**A3. Gateway plus EnvoyProxy.**
- `envoyService.type: ClusterIP`, with a fixed ClusterIP in the static band.
  Set it via the EnvoyProxy service patch, like `authentik.serviceIP`
  [I: confirm the patch path].
- A ClientTrafficPolicy with `customHeader: Cf-Connecting-Ip`,
  `failClosed: true`, plus the early `Set` of X-Forwarded-For.
- Deploy podinfo as the test route.
- Verify, from r440:
  1. `curl -H 'Cf-Connecting-Ip: 203.0.113.9' -H 'X-Forwarded-For: 6.6.6.6' http://<gw-ip>/headers`
     shows `X-Forwarded-For: 203.0.113.9` only.
  2. A request without the header is rejected (failClosed).
- Rollback: Flux revert.

**A4. Host cloudflared routes to the Gateway.**
- Change: a host change on r440. Add a separate tunnel for app hostnames to
  `hosts/r440/`, with ingress `http://<gw-ip>:80`.
- Switch r440 only, then run the etcd health check
  (`docs/cluster-handoff.md`).
- Verify: the public hostname reaches podinfo with the right client IP.
- Rollback: `nixos-rebuild switch --rollback` on r440.
- authentik is **not** moved; it keeps its own tunnel and nginx.

**A5 (optional). Lock down the Gateway Service.**
- Only cloudflared (r440 host) should reach it.
- Flannel doesn't enforce NetworkPolicy, so use a host-side rule:
  `iptables` on r440, or keep the Gateway reachable only via ClusterIP from
  the host. Record this residual risk [I].

**Time estimate:** about 1 day of work across 4–5 PRs. No node downtime.

### Plan B (only if Cilium is wanted for its own sake): gated CNI migration

Do Plan A first; Envoy Gateway runs fine on Cilium later too. Each step is
one PR. Switch hosts one at a time in the order m2mini → r440 → c4130. Run
the etcd health check after each switch. GC old generations on c4130 before
its switch. Never touch vLLM: it is a host service, and the per-node switch
only recycles pods.

**B0. Go/no-go checks.** No PR; a read-only session with the user's
permission to SSH.
- m2mini: `VA_BITS`, `/sys/kernel/btf/vmlinux`, and run the pinned
  cilium-envoy image once.
- Every node: `tailscale version`. 1.98.0–1.98.3 means pin or add the
  sysctl workaround.
- Every node: TPROXY modules.
- **Stop conditions:**
  - If BTF is missing on any node, stop.
  - If Envoy fails on m2mini, continue only with m2mini set to
    `enable-l7-proxy=false`.

**B1. NixOS prep, no behaviour change.**
- In `cluster/definition.nix`, add `nodes.<n>.cni` (default `"flannel"`) and
  `ciliumPodCidr = "10.245.0.0/16"`.
- In `node.nix`, ship `05-cilium.conflist` only when `cni = "cilium"`, and
  add a Nix-packaged `cilium-cni` to `kubelet.cni.packages`.
- In `firewall.nix`, open 8473/udp, 4240/tcp, ICMP and 4244/tcp from node
  IPs, plus 10.245/16 in the pod→apiserver/kubelet rule.
- Set `checkReversePath = "loose"`.
- Apply the Tailscale fix from B0, if needed.
- Switch hosts one at a time, with an etcd health check after each.
- Verify: pods are unchanged and `iptables -S nixos-fw` shows the new rules.
- Rollback: generation rollback.

**B2. Cilium chart with migration values.**
- Pin `charts.cilium` 1.20.4 and add `k8s/components/cilium.nix`.
- Values:
  - The migration values (`tunnelPort=8473`, cluster-pool 10.245/16,
    `customConf=true`, `policyEnforcementMode=never`,
    `hostLegacyRouting=true`).
  - `k8sServiceHost=10.0.0.200`, `k8sServicePort=6443`.
  - `kubeProxyReplacement=false`.
  - `cni.install=false`, `sysctlfix.enabled=false`.
  - Explicit `devices` (`eno1`, `end0`).
  - `gatewayAPI.enabled=false`.
- Verify: `cilium status` shows all agents OK and they manage 0 pods.
- Rollback: Flux revert.

**B3–B5. Switch nodes one by one: m2mini, then r440, then c4130.**
- One PR per node, setting `nodes.<n>.cni = "cilium"`.
- Per node:
  1. Drain the node.
  2. Merge and switch.
  3. Recycle its pods.
  4. Verify: a netshoot pod gets a 10.245 address, and DNS and the
     apiserver work.
  5. Run the etcd health check.
  6. Uncordon.
- **r440 PR only:** also update `AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS`.
  Replace `10.244.0.1/32` with r440's new `cilium_host` address. Then verify
  that an auth.neuros.is login shows the real client IP in authentik's event
  log.
- **c4130:**
  1. GC old generations first.
  2. Don't reboot. Delete the remaining flannel pods, and remove
     `cni0`/`flannel.1` later.
  3. Confirm `systemctl is-active vllm` before and after.
- Rollback for each node: set the node back to `"flannel"` and recycle its
  pods.

**B6. Finalize.**
- Set `policyEnforcementMode=default` and `unmanagedPodWatcher.restart=true`.
  Keep `hostLegacyRouting=true`.
- Check the Flux NetworkPolicies now that they are enforced.
- Remove the flannel component, `10-flannel.conflist` and 8472/udp, and move
  `podCidr` to 10.245/16.
- Rollback from here is expensive (reinstall flannel), so soak B3–B5 for at
  least a week first.

**B7. KPR, in a separate window.**
- One PR sets `kubeProxyReplacement=true`. Then one host PR per node sets
  `services.kubernetes.proxy.enable=false` and does the KUBE-* cleanup.
- Expect one connection reset per node.
- Verify: cloudflared → nginx → 10.96.0.20 on r440, a login via OIDC
  (`kubectl` with an authentik token), and vLLM :8000 from the LAN and the
  tailnet.
- Rollback: re-enable proxy and set KPR false.

**B8. Optional: Cilium Gateway** (host network mode on r440, port above 1023).
- Only worth it if it replaces Envoy Gateway. It changes nothing for
  authentik, which stays behind nginx.

**Time estimate:** about 1–2 weeks of calendar time with soaks; roughly
2–3 days of hands-on work, plus about 5 maintenance windows.

## Sources

- [gw] https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/ (1.20.4)
- [upg] https://docs.cilium.io/en/stable/operations/upgrade/
- [helm] https://docs.cilium.io/en/stable/helm-reference/
- [envoy] https://docs.cilium.io/en/stable/security/network/proxy/envoy/
- [l2] https://docs.cilium.io/en/stable/network/l2-announcements/ and https://docs.cilium.io/en/stable/network/lb-ipam/
- [mig] https://docs.cilium.io/en/stable/installation/k8s-install-migration/
- [kpr] https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
- [compat] https://docs.cilium.io/en/stable/network/kubernetes/compatibility/ and https://docs.cilium.io/en/stable/operations/system_requirements/
- Cilium releases: https://github.com/cilium/cilium/releases. Source at
  `v1.20.4`: `operator/pkg/model/translation/`,
  `operator/pkg/model/ingestion/gateway.go`,
  `pkg/ciliumenvoyconfig/cec_resource_parser.go`
- Cilium issues: cilium/cilium#36104, #46422, #47718, #47940, #48695,
  #48706, #48778, #49587, #49943, #21916, #48936. cilium/proxy#1027
- tcmalloc and Envoy: google/tcmalloc#82, envoyproxy/envoy#15235, #17854.
  https://asahilinux.org/docs/sw/broken-software/ and
  https://lwn.net/Articles/996405/
- Tailscale: tailscale/tailscale#19796 and
  https://tailscale.com/docs/kubernetes-operator/reference/compatibility
- Envoy headers: https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_conn_man/headers
- authentik: https://docs.goauthentik.io/install-config/configuration/.
  Source: `packages/ak-axum/src/extract/client_ip.rs`,
  `authentik/root/middleware.py`
- Envoy Gateway: https://gateway.envoyproxy.io/docs/tasks/traffic/client-traffic-policy/,
  https://gateway.envoyproxy.io/news/releases/v1.9/. Source at `v1.10.0`:
  `api/v1alpha1/{clienttrafficpolicy,shared,envoyproxy}_types.go`
- NGINX Gateway Fabric: https://docs.nginx.com/nginx-gateway-fabric/reference/api/.
  Source at `v2.8.1`: `apis/v1alpha2/nginxproxy_types.go`
- Traefik: https://doc.traefik.io/traefik/reference/install-configuration/entrypoints/
  and BetterCorp/cloudflarewarp
- Conformance: https://gateway-api.sigs.k8s.io/implementations/
- [ingnx] https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/
- [cf-ha] https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-availability/
- nixpkgs `nixos-26.05`: `nixos/modules/services/cluster/kubernetes/kubelet.nix`,
  `services/networking/firewall*.nix`. nixpkgs#53601
