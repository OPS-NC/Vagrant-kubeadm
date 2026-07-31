<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🐝 `cilium/` — CNI, LoadBalancer IPs and L2 announcement (ARP)

> **The networking component of the lab.** Cilium provides the CNI (without it the nodes stay
> `NotReady`) and also plays the "cloud provider" role: it hands `type: LoadBalancer` Services a
> **real IP from the host-only network** `192.168.56.0/24` and announces it over **ARP**. That
> mechanism is what produces the `192.168.56.200` VIP of the Envoy entry point — no MetalLB
> involved.

## 🎯 Purpose

- **CNI** in **VXLAN** tunnel mode, pinned to the host-only interface (see ⚠️ Pitfalls).
- **LoadBalancer IPs**: a `.200-.230` pool stands in for the missing cloud provider.
- **L2 announcement (ARP)**: the IP becomes reachable from the host, hence over Tailscale
  (see [`../README.md`](../README.md), "Remote access" section).
- **Network observability**: Hubble (relay + UI) is enabled, handy for showing flows.

## 📋 Prerequisites

| Prerequisite | Why | Check |
|---|---|---|
| Cluster bootstrapped with **`CNI=cilium`** (`./kubeadm/cluster-up.sh`, the default — `CNI=none` is equivalent here) | `kubeadm init` installs no CNI at all: Cilium takes that slot | `kubectl get nodes` → `NotReady` **before** the install, that is expected |
| `_out/cluster.env` present | it carries the **detected** facts the script reads: `HOSTONLY_IF`, `POD_CIDR`, `VIP`, `KUBE_PROXY_REPLACEMENT` | `cat _out/cluster.env` |
| A host-only interface (usually **`enp0s8`**) | source of the ARP announcement **and** of the VXLAN tunnels | `vagrant ssh k8s-cp1 -c 'ip -br a'` |
| `kubectl` + `helm`, `KUBECONFIG` set | the script checks the binaries, then `/readyz` | `helm version` |

## ⚡ Install

```bash
./_k8s/cilium/cilium-up.sh
```

Chart `cilium/cilium` **`1.20.0`**, read from `lab.env` (`CILIUM_VERSION`) and overridable per run
(`CILIUM_VERSION=1.20.1 ./_k8s/cilium/cilium-up.sh`). Idempotent (`helm upgrade --install` +
`kubectl apply`). `../platform-up.sh` calls it as step **[1/4]** — so there is nothing to run
here if you go through the full platform.

> ⚠️ **Do not take §9 of the root README as the installation reference.** It shows the "manual"
> `helm upgrade` to explain who installs the CNI, but **without `--version`** (you get the latest
> published release, not the one validated here) and **without applying `cilium-l2.yml`** — so
> without an IP pool: the Gateway would stay at `EXTERNAL-IP <pending>`. The source of truth is
> `cilium-up.sh`.

## 🔧 What the script does

1. **Reads `_out/cluster.env`** (then `lab.env` as a fallback): `HOSTONLY_IF`, `POD_CIDR`, `VIP`,
   `KUBE_PROXY_REPLACEMENT` — detected facts, not guesses;
2. **installs Cilium with Helm** in `kube-system` with the values below;
3. **waits** for `condition=Ready` on every node (300 s max) — the CNI is what unblocks them;
4. **applies `cilium-l2.yml`**: LoadBalancer IP pool + ARP announcement policy, with the pool
   range and the interface name substituted in.

### The `--set` flags that matter

| Setting | Why |
|---|---|
| `devices=<HOSTONLY_IF>` | **the key one**: pins the **host-only** NIC (read from `_out/cluster.env`, never hardcoded). Without it, Cilium picks the NIC carrying the default route (NAT `10.0.2.15`, identical on every VM) → unusable VTEP and ARP |
| `routingMode=tunnel` + `tunnelProtocol=vxlan` | encapsulation between nodes. There is **no router** on the host-only network, so native routing would need a static route per node on the VirtualBox side: tunnelling avoids the whole problem |
| `ipam.mode=cluster-pool` + `ipam.operator.clusterPoolIPv4PodCIDRList={<POD_CIDR>}` + `clusterPoolIPv4MaskSize=24` | ⚠️ **the trap**: the cluster-pool default is `10.0.0.0/8`, completely independent from the `podSubnet` declared to kubeadm. Without passing `POD_CIDR` back explicitly, kubeadm and Cilium do not talk about the same network |
| `kubeProxyReplacement=<KUBE_PROXY_REPLACEMENT>` | `true` (default): `kubeadm init` ran with `--skip-phases=addon/kube-proxy`, there is **no kube-proxy at all** and Cilium serves the Services in eBPF. `false`: kube-proxy is there, Cilium sits on top |
| `k8sServiceHost=<VIP>` + `k8sServicePort=6443` | **mandatory without kube-proxy**: nothing provisions the apiserver ClusterIP any more, so the agent cannot bootstrap through `kubernetes.default`. We point at the **keepalived VIP**, not at cp1's own IP: the VIP survives losing cp1, and it is the address already baked into the certificates |
| `l2announcements.enabled=true` | **enables** the controller that answers ARP; without it the `CiliumL2AnnouncementPolicy` is ignored |
| `externalIPs.enabled=true` | support for Service `externalIPs` |
| `envoy.enabled=false` | no need for Cilium's **embedded** Envoy: the lab uses the [`../envoy-gateway/`](../envoy-gateway/README.md) controller, a separate component |
| `hubble.*` + `bandwidthManager.enabled=true` | flow observability + bandwidth management (demos) |

> ⚠️ **What is deliberately *absent*.** The Cilium docs' Talos page recommends
> `cgroup.autoMount.enabled=false`, `cgroup.hostRoot=/sys/fs/cgroup` and explicit
> `securityContext.capabilities.*` lists. Those are **Talos** workarounds and they are actively
> harmful on Debian: the chart mounts cgroup2 itself and computes the capabilities the agent
> needs. Do not copy them back in.

### `cilium-l2.yml` — two objects

| Object | Role |
|---|---|
| `CiliumLoadBalancerIPPool` **`lb-pool-56`** | reserves the **`.200` → `.230`** range; every `LoadBalancer` Service draws from it |
| `CiliumL2AnnouncementPolicy` **`l2-lb-workers`** | **announces those IPs over ARP** on the host-only NIC, **from the workers only** (control planes are excluded by the `nodeSelector`) |

Why these choices:

- **`.200-.230` range**: clear of the node IPs (CP `.10/.20/.30`, workers `.101+`), of the API
  VIP `.5` and of the gateway `.1`. Keep it aligned if you change the IP plan in `lab.env`.
- **Host-only interface**: the only NIC through which the host can reach the VMs. The manifest
  ships `^enp0s8$` as the default; `cilium-up.sh` rewrites it from `HOSTONLY_IF` in
  `_out/cluster.env`, so a box that names it `eth1` works with no edit.
- **Workers only**: keeps a control plane from answering ARP for the VIP. On a single-node
  topology (no worker), you have to drop the `nodeSelector`, otherwise nobody announces anything.

## ✅ Verify

```bash
kubectl -n kube-system get pods -l k8s-app=cilium              # one agent per node, Running
kubectl get nodes                                              # all Ready
kubectl get ciliumloadbalancerippool                           # lb-pool-56, DISABLED=false, IPS AVAILABLE
kubectl get ciliuml2announcementpolicy                         # l2-lb-workers
kubectl -n envoy-gateway-system get svc                        # EXTERNAL-IP = 192.168.56.200
ping -c1 192.168.56.200                                        # from the host: ARP must answer

# Agent-side diagnostics. ⚠️ the in-pod binary was RENAMED `cilium` -> `cilium-dbg` in
# v1.15: `... -- cilium status` no longer exists.
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list   # empty => no eBPF Services
```

With `KUBE_PROXY_REPLACEMENT=true` there is **no `kube-proxy` DaemonSet** in `kube-system`, and
that is the expected state — `cilium-dbg status` must report `KubeProxyReplacement: True`.

## 🌐 Hubble UI (not exposed)

Hubble is enabled but **no `HTTPRoute` exposes it**: that is deliberate (the UI has no
authentication). One-off access through a port-forward:

```bash
kubectl -n kube-system port-forward svc/hubble-ui 12000:80     # then http://localhost:12000
```

## ⚠️ Pitfalls

- **Service stuck at `EXTERNAL-IP: <pending>`** → missing pool (`cilium-l2.yml` not applied),
  exhausted range, or `l2announcements` not enabled at install time (the typical case when you
  followed §9 of the root README instead of `cilium-up.sh`).
- **VIP that answers `ping` from the host but not from a Tailscale peer** → expected: ARP does
  not cross a router. You need `--advertise-routes` on the host
  (see [`../README.md`](../README.md)).
- **`--set autoDirectNodeRoutes=true` (or `ipv4NativeRoutingCIDR`) is forbidden here**: those are
  **native routing** options, incompatible with tunnel mode. The agent exits `fatal`
  ("auto-direct-node-routes cannot be used with tunneling") and loops in `CrashLoopBackOff`.
- **Replacing kube-proxy is decided at bootstrap, not here.** `KUBE_PROXY_REPLACEMENT=true` makes
  `kubeadm/cluster-up.sh` run `kubeadm init --skip-phases=addon/kube-proxy`; this script then
  reads the same value back from `_out/cluster.env`. Flipping only one of the two loses every
  Service in the cluster. Changing your mind means rebuilding: `./kubeadm/cluster-reset.sh` then
  `./kubeadm/cluster-up.sh`.
- **`k8sServiceHost` is not optional without kube-proxy.** Nothing provisions the
  `10.96.0.1` apiserver ClusterIP any more, so an agent that only knows `kubernetes.default`
  never connects and stays in `CrashLoopBackOff` on `Unable to contact k8s api-server`.
- **Pod CIDR mismatch.** `ipam.mode=cluster-pool` defaults to `10.0.0.0/8` regardless of the
  `podSubnet` given to kubeadm. Symptom: pods get `10.0.x.x` addresses while
  `kubectl get node -o jsonpath='{.spec.podCIDR}'` says `10.244.x.0/24`. Always pass
  `POD_CIDR` back (the script does).
- **Do not re-run the script to "refresh" a cluster that is running a demo** without reading the
  Helm diff: changing `routingMode` or `devices` cuts traffic while the agents redeploy.
- **The two objects do NOT share an apiVersion**, and that asymmetry is deliberate — verified
  against the Cilium 1.20.0 docs:
  `CiliumLoadBalancerIPPool` is `cilium.io/v2`, while `CiliumL2AnnouncementPolicy` is still
  `cilium.io/v2alpha1`. Aligning them "for consistency" is the mistake to avoid: the pool
  silently stops being served on `v2alpha1`, and the Gateway goes back to `<pending>`.
  If a future Cilium promotes the policy to `v2`, the symptom is an `apiVersion` rejection at
  `kubectl apply` — check with
  `kubectl get crd ciliuml2announcementpolicies.cilium.io -o jsonpath='{.spec.versions[*].name}'`.

## 📚 References

- [Cilium — kube-proxy replacement](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
- [Cilium — IPAM cluster-pool](https://docs.cilium.io/en/stable/network/concepts/ipam/cluster-pool/)
- [Cilium — LoadBalancer IPAM](https://docs.cilium.io/en/stable/network/lb-ipam/)
- [Cilium — L2 Announcements](https://docs.cilium.io/en/stable/network/l2-announcements/)
- [`../envoy-gateway/README.md`](../envoy-gateway/README.md) — the consumer of the `.200` VIP
