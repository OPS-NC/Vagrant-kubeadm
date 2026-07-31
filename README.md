<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🏠 ☸️ Vagrant-KubeADM

> Build a **Kubernetes 1.36 cluster the hard way — with `kubeadm`, on Debian 13** VMs running
> on **VirtualBox**. `vagrant up` prepares the machines, one script chains the `kubeadm`
> commands, and a full application layer (Cilium, Envoy Gateway, Longhorn, Vault,
> PostgreSQL…) comes on top. Single control plane or **HA with 3 CPs behind a keepalived VIP**.

This lab is deliberately **not** a turnkey installer. Every VM is an ordinary Debian box with
SSH and `apt`; every step the scripts take is a `kubeadm` command you could type yourself, and
§5 shows exactly which ones. What the repo adds is the boring,
error-prone part: the VIP that must exist *before* `kubeadm init`, the `node-ip` every Vagrant
lab gets wrong, the containerd 2.x config, the certificate SANs you cannot add afterwards.

**The whole path, in three commands:**

```bash
cp lab.env.example lab.env      # pick the topology
vagrant up                      # creates and PREPARES the VMs (no cluster yet)
./kubeadm/cluster-up.sh         # kubeadm init + join + kubeconfig
./_k8s/platform-up.sh           # CNI, Envoy Gateway, metrics-server, wildcard TLS
```

| | |
|---|---|
| 📖 **Browsable docs** | `make docs` — one self-contained HTML page, EN/FR switch, light/dark theme, no CDN. See §11 for publishing it on GitHub Pages. |
| 📦 **Application layer** | [`_k8s/README.md`](_k8s/README.md) |
| ⬆️ **Kubernetes upgrades** | [`kubeadm/UPGRADE.md`](kubeadm/UPGRADE.md) |
| 🚑 **Something broken?** | [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) |

> ℹ️ **There is a twin repo, [Vagrant-Talos](https://github.com/OPS-NC/Vagrant-Talos).** Same
> lab, same IP plan, same `_k8s/` layer — opposite OS and opposite operating model. Talos is
> immutable, has no SSH and no package manager, and is driven entirely through an API from the
> host. Here you get a normal distribution and you drive `kubeadm` yourself: more moving
> parts, and that is the point — this repo is where you see what an installer usually hides.

---

## 🧰 1. Prerequisites (on the host)

| Tool | Purpose | Install |
|---|---|---|
| VirtualBox 7 | hypervisor | https://www.virtualbox.org/ |
| Vagrant | VM creation | https://developer.hashicorp.com/vagrant |
| `kubectl` | using the cluster | https://kubernetes.io/docs/tasks/tools/ |
| `helm` | `_k8s/` addons | https://helm.sh/docs/intro/install/ |
| `uv` *(optional)* | `make docs` | https://docs.astral.sh/uv/ |

That is the complete list. **There is no `talosctl` here, and no cluster-specific binary to
install on your machine**: `kubeadm`, `kubelet`, `kubectl` and `containerd` live *inside* the
VMs, installed by [`kubeadm/provision.sh`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/provision.sh) during `vagrant up`. The
Debian box (`bento/debian-13`) is downloaded by Vagrant on first use; no plugin is required.

`kubeadm/cluster-up.sh` checks for exactly two of these up front (`vagrant`, `kubectl`) and
refuses to start without them.

> 💡 **`kubectl` on the host should be within one minor of the cluster** (1.35 → 1.37 for a
> 1.36 cluster). If yours is older, you can always fall back to the in-VM one:
> `vagrant ssh k8s-cp1 -c 'kubectl get nodes -o wide'` — `node-init.sh` installs a kubeconfig
> for both `root` and `vagrant`.

> ⚠️ **VirtualBox and KVM cannot share VT-x.** If the KVM module is loaded, `vagrant up` dies
> on `VERR_VMX_IN_VMX_ROOT_MODE`. Unload it (`sudo modprobe -r kvm_intel kvm` /
> `kvm_amd`) before starting — details in [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

---

## 🗺️ 2. IP plan (host-only network `192.168.56.0/24`)

| Item | IP |
|---|---|
| Host (host-only gateway) | `192.168.56.1` |
| VirtualBox DHCP server | `192.168.56.2` |
| **Kubernetes API VIP** (keepalived) | **`192.168.56.5`** |
| `k8s-cp1` / `cp2` / `cp3` | `192.168.56.10` / `.20` / `.30` |
| `k8s-w1` / `w2` / `w3` … | `192.168.56.101` / `.102` / `.103` … |
| VirtualBox default host-only DHCP (reserved) | `192.168.56.100` |
| LoadBalancer range (Cilium L2 announcement) | `192.168.56.200` – `.230` |
| **Envoy Gateway IP** (wildcard DNS target) | `192.168.56.200` — the 1st of the range |

Pod network `10.244.0.0/16`, Service network `10.96.0.0/12`.

The node IPs are **static**, assigned by the `Vagrantfile` (`private_network`), not by DHCP.
The `Vagrantfile` refuses to start if a computed node IP lands on `.1`, `.2`, `.100` or on the
VIP, and refuses duplicates — those produce labs that break in extremely obscure ways.

Every VM has **2 NICs**: **NIC1 = VirtualBox NAT** (Internet, same `10.0.2.15` on *every* VM)
and **NIC2 = host-only** `192.168.56.x` (cluster, API, etcd, pod traffic). The default route
goes through the NAT — that is deliberate, it is how the VMs reach `apt` and the registries.
What must be host-only is the node's *identity*, never its default route: see the `node-ip`
discussion in §9.

> ℹ️ **The host-only interface name is never hard-coded.** Debian 13 normally names it
> `enp0s8`, but some box builds still expose `eth1`. `provision.sh` finds it by looking for
> the interface that *carries the node's IP* (falling back to the route for
> `192.168.56.0/24`), writes it to `/etc/kubeadm-lab/node.env`, and `cluster-up.sh` copies it
> into `_out/cluster.env` as `HOSTONLY_IF`. keepalived binds VRRP to it, and the `_k8s/`
> scripts hand it to Cilium for L2 announcement — a wrong name there means a VIP that never
> comes up and Services that never answer.

> ℹ️ Name resolution does not depend on DNS or on boot order: the `Vagrantfile` pushes an
> identical `/etc/hosts` block to every node (all node names, plus `kubernetes-api` for the
> VIP), and `provision.sh` deletes Debian's `127.0.1.1 <hostname>` line — left in place, the
> kubelet resolves its own name to loopback and the node registers as unreachable.

---

## ⚙️ 3. Pick the topology — `lab.env`

The topology lives in **`lab.env`**, the single source read by the `Vagrantfile`, by
`kubeadm/cluster-up.sh` **and** by the `_k8s/*-up.sh` scripts. Start from the versioned
template ([`lab.env.example`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/lab.env.example); `lab.env` itself is gitignored):

```bash
cp lab.env.example lab.env
```

Format is strict: one `KEY=value` per line, no spaces around `=`. A real environment variable
always wins, which makes one-off overrides possible: `WORKERS=5 vagrant up`.

| Variable | Template default | Purpose |
|---|---|---|
| `K8S_VERSION` | `1.36.3` | version installed (`kubelet`/`kubeadm`/`kubectl`, pinned then `apt-mark hold`) |
| `K8S_APT_MINOR` | `v1.36` | `pkgs.k8s.io` repository minor — **must match `K8S_VERSION`** |
| `CONTAINERD_SOURCE` | `docker` | `docker` → `containerd.io` 2.x (Docker repo) · `debian` → containerd 1.7 (see §9) |
| `REGISTRY_MIRROR` | *(empty)* | pull-through mirror (Harbor…) → `/etc/containerd/certs.d/docker.io/hosts.toml` |
| `CONTROL_PLANES` | `1` | `1` = single, `3` = HA. **Even numbers are refused** |
| `WORKERS` | `2` | number of workers; `0` is valid (see `UNTAINT_CP`) |
| `CP_MEM` / `CP_CPU` | `3072` / `2` | control plane resources (**never below `3072`**: etcd) |
| `WK_MEM` / `WK_CPU` | `2048` / `2` | worker resources |
| `BOX` | `bento/debian-13` | Vagrant box — the lab is written and tested for Debian 13 |
| `NODE_PREFIX` | `k8s` | VM/node names: `k8s-cp1`, `k8s-w1`… |
| `CLUSTER_NAME` | `kubeadm-lab` | kubeadm `clusterName` + kubeconfig context |
| `NETWORK` | `192.168.56` | host-only network (first 3 octets) |
| `VIP` | `192.168.56.5` | API VIP = `controlPlaneEndpoint`, carried by keepalived |
| `CP_IP_START` / `CP_IP_STEP` | `10` / `10` | → `.10`, `.20`, `.30` |
| `WK_IP_START` / `WK_IP_STEP` | `101` / `1` | → `.101`, `.102`, `.103` |
| `POD_CIDR` | `10.244.0.0/16` | kubeadm `networking.podSubnet` — **the CNI must announce the same one** |
| `SERVICE_CIDR` | `10.96.0.0/12` | kubeadm `networking.serviceSubnet` |
| `LB_POOL_START` / `LB_POOL_END` | `192.168.56.200` / `.230` | `LoadBalancer` IP range; **the 1st one is the Gateway's**, the wildcard DNS target |
| `VRRP_ROUTER_ID` | `51` | keepalived VRRP group (1-255); change it only to coexist with another keepalived lab |
| `CNI` | `cilium` | `cilium`, `calico`, `flannel` or `none` (see §10) |
| `CILIUM_VERSION` | `1.20.0` | Cilium chart version (ignored unless `CNI=cilium`) |
| `KUBE_PROXY_REPLACEMENT` | `true` | eBPF replacement of kube-proxy — **requires `CNI=cilium`** |
| `UNTAINT_CP` | `auto` | remove the control-plane taint: `auto` (only if `WORKERS=0`), `true`, `false` |
| `LAB_DOMAIN` | `kubeadm.lab.example.io` | UI domain (`*.<domain>`: wildcard TLS + `HTTPRoute`) |
| `SELF_SIGNED` | `true` | TLS mode: `true` = wildcard signed by a local CA (`openssl`, no domain, no token), `false` = cert-manager + Let's Encrypt |
| `LAB_DNS_ZONE` | *(empty → last 2 labels)* | DNS zone of the ACME DNS-01 solver — `SELF_SIGNED=false` only |
| `LAB_ACME_EMAIL` | *(empty → `admin@<zone>`)* | Let's Encrypt account (expiry notices) — `SELF_SIGNED=false` only |
| `LAB_ACME_ISSUER` | `staging` | ACME issuer: `staging` (untrusted, huge quota) or `prod` (trusted, **5 certs/week**) — `SELF_SIGNED=false` only |
| `CLOUDFLARE_API_TOKEN` | *(empty)* | cert-manager DNS-01 — `SELF_SIGNED=false` only, and **never** in the versioned template |

Read by `cluster-up.sh` but absent from the template (both have a default): `OUT` (`_out`, the
directory rendered configs go to) and `WAIT_API` (`600`, seconds to wait for the apiserver on
the VIP).

> 💰 **What each topology costs.** Default (1 CP + 2 workers): **7 GB of RAM**, 6 vCPU.
> Full HA (`CONTROL_PLANES=3`, `WORKERS=3`): 3 × 3072 + 3 × 2048 = **15.4 GB**, 12 vCPU. VM
> disks are linked clones, so the box is stored roughly once.

> ⚠️ **An even number of control planes is refused**, by the `Vagrantfile` *and* by
> `cluster-up.sh`. etcd holds quorum at `(n/2)+1`: with 2 members, losing a single node
> freezes the API — twice the cost of a single CP, and strictly less availability. Stay on
> 1, 3 or 5. (CI has a test asserting this guard actually fires.)

> ⚠️ **Do not lower `CP_MEM` below `3072`.** The kubeadm preflight demands 2 vCPU and
> ~1700 MiB; 2048 passes but leaves ~350 MiB of headroom for a stacked etcd, which collapses
> as soon as the `_k8s/` addons pile up. `_k8s/observability/` explicitly wants `4096`.

> ⚠️ **`K8S_VERSION` and `K8S_APT_MINOR` must agree.** The `pkgs.k8s.io` repositories are
> per-minor: a `v1.36` repo cannot serve a `1.35.x` package, and `apt` then fails with a
> version-not-found error that says nothing about the mismatch. That pair is what you bump for
> an upgrade — see [`kubeadm/UPGRADE.md`](kubeadm/UPGRADE.md).

> 💡 **Create `lab.env` anyway.** Without it the `Vagrantfile` and `cluster-up.sh` each fall
> back to their internal defaults. They are kept aligned on purpose — `make validate-defaults`
> enforces it key by key — but they remain two separate copies: the day they drift, you get
> 1.36 packages configured for 1.35. One file, one truth.

---

## 🚀 4. Start the cluster

```bash
vagrant up                      # 5-10 min: VMs + packages + containerd + kubeadm + keepalived
./kubeadm/cluster-up.sh         # 3-5 min: init + joins + kubeconfig
```

**`vagrant up` bootstraps nothing.** It creates the VMs and runs
[`kubeadm/provision.sh`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/provision.sh) in each one, which lays down, in order:
`/etc/hosts` · swap off + kernel modules + sysctl · base packages (`conntrack`, `socat`,
`ethtool`, `open-iscsi`, `nfs-common`…) · containerd with `SystemdCgroup = true` ·
`kubelet`/`kubeadm`/`kubectl` pinned and held · **pre-pulled images** · and, on control planes
only, **keepalived carrying the VIP**. At the end of `vagrant up` each VM is ready to receive
a `kubeadm init` or `join`, and nothing more.

`cluster-up.sh` then prints five steps:

| Step | What happens |
|---|---|
| `[1/5]` | renders the kubeadm configs into `_out/` **on the host** (`certsans.txt`, `kubeadm-init.yaml`) from [`kubeadm/templates/`](https://github.com/OPS-NC/Vagrant-kubeadm/tree/main/kubeadm/templates) |
| `[2/5]` | `kubeadm init` on the 1st CP via `vagrant ssh` → [`node-init.sh`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/node-init.sh); copies `admin.conf` to `./kubeconfig`; **waits for `https://<VIP>:6443/readyz`** |
| `[3/5]` | joins the secondary control planes, **one at a time** (etcd accepts one membership change at a time) |
| `[4/5]` | joins the workers |
| `[5/5]` | untaints per `UNTAINT_CP`, labels the workers `node-role.kubernetes.io/worker=`, writes `_out/cluster.env` (including the detected `HOSTONLY_IF`) |

Before touching anything it validates the config (`CNI` value, the
`KUBE_PROXY_REPLACEMENT`/`CNI` pair, odd number of CPs) and checks that **all** the expected
VMs are `running` — diagnosing that up front costs a second, diagnosing it later means a
`vagrant ssh` timing out in the middle of a half-finished `join`.

Then, from the host:

```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide
```

The kubeconfig needs no editing: its `server:` is already the VIP, reachable from the host over
the host-only network.

> ⚠️ **The nodes will be `NotReady`, and that is NORMAL.** This is the number-one question of
> anyone discovering kubeadm: **kubeadm never installs a CNI**. Until a pod network is in
> place, the kubelet reports `NetworkReady=false` / `cni plugin not initialized`, CoreDNS
> stays `Pending`, and the nodes stay `NotReady`. The next command is what fixes it:
> `./_k8s/platform-up.sh` (§6).

> 💡 **`cluster-up.sh` is idempotent** and safe to re-run: `node-init.sh` refuses to re-run
> `kubeadm init` if `/etc/kubernetes/admin.conf` exists, `node-join.sh` skips any node that
> already has `/etc/kubernetes/kubelet.conf`. Re-running it is also **how you grow the lab**
> (§7.1).

> ℹ️ Join credentials are regenerated on **every** run — the bootstrap token created by
> `init` expires after 24 h and the certificate key after 2 h. A `cluster-up.sh` run three
> days after the initial `init` therefore just works, instead of failing with an opaque
> discovery error.

For another topology, edit `lab.env` — or override on the spot, **passing the variable to both
commands**, since each re-reads its own environment:

```bash
CONTROL_PLANES=3 WORKERS=3 vagrant up
CONTROL_PLANES=3 WORKERS=3 ./kubeadm/cluster-up.sh
```

---

## 🎓 5. Doing it by hand

This is what the lab is *for*. Everything `cluster-up.sh` does is a `kubeadm` command you can
type yourself; the scripts exist so you do not have to retype them at every rebuild, not to
hide them. Below is the same path, by hand, on a lab that has been `vagrant up`-ed.

### 5.1 What is already in place after `vagrant up`

```bash
vagrant ssh k8s-cp1
sudo -i
kubeadm version -o short                 # v1.36.3, held by apt-mark
containerd --version                     # 2.x when CONTAINERD_SOURCE=docker
crictl ps                                # talks to /run/containerd/containerd.sock
ip -4 addr show | grep 192.168.56.5      # the VIP is ALREADY there, before any init
systemctl status keepalived
cat /etc/kubeadm-lab/node.env            # NODE_IP, HOSTONLY_IF, VIP…
```

> ℹ️ The VIP being up **before** `kubeadm init` is the whole reason keepalived is used here
> rather than kube-vip — the reasoning is in §9.

### 5.2 `kubeadm init` on the first control plane

The repo's way, which is also the shortest — `cluster-up.sh` already rendered the config into
`_out/`, visible from the VM through the synced folder:

```bash
sudo kubeadm init --config /vagrant/_out/kubeadm-init.yaml --upload-certs \
     --skip-phases=addon/kube-proxy          # only when KUBE_PROXY_REPLACEMENT=true
```

The flag-only equivalent, if you want to see it without a config file:

```bash
sudo kubeadm init \
  --control-plane-endpoint 192.168.56.5:6443 \
  --apiserver-advertise-address 192.168.56.10 \
  --pod-network-cidr 10.244.0.0/16 \
  --service-cidr 10.96.0.0/12 \
  --cri-socket unix:///run/containerd/containerd.sock \
  --apiserver-cert-extra-sans 192.168.56.5,192.168.56.10,192.168.56.20,192.168.56.30 \
  --upload-certs \
  --skip-phases=addon/kube-proxy
```

Note the two addresses, which are **not** the same thing: `--apiserver-advertise-address` is
the *real* IP this apiserver listens on, `--control-plane-endpoint` is the *shared* VIP that
gets baked into the certificates and every kubeconfig.

> ⚠️ **This flag form cannot set `node-ip`, and that is why the repo uses `--config`.** With
> flags alone the kubelet picks the default-route NIC — the NAT, `10.0.2.15`, **identical on
> every VM**. All nodes then register with the same address: `kubectl get nodes -o wide` looks
> plausible, while logs, `kubectl exec`, probes and inter-node traffic all go to the wrong
> place. `kubeadm init/join` has no equivalent flag; the setting only exists as
> `nodeRegistration.kubeletExtraArgs`.

> ⚠️ **`--upload-certs` is what makes HA possible later.** It stores the cluster CAs in the
> `kubeadm-certs` Secret, encrypted with the certificate key. Without it, a second control
> plane can only join after you copy `/etc/kubernetes/pki` by hand.

> ⚠️ **certSANs cannot be added afterwards** — not without regenerating the API certificate.
> That is why the lab lists **5** control-plane IPs up front, including nodes that do not
> exist yet: growing the cluster later never requires touching the PKI.

### 5.3 Getting a kubeconfig

In the VM:

```bash
mkdir -p "$HOME/.kube"
sudo install -o "$(id -u)" -g "$(id -g)" -m 0600 /etc/kubernetes/admin.conf "$HOME/.kube/config"
kubectl get nodes
```

On the host — no `scp`, the synced folder is right there:

```bash
vagrant ssh k8s-cp1 -c 'sudo cat /etc/kubernetes/admin.conf' > kubeconfig
chmod 0600 kubeconfig && export KUBECONFIG="$PWD/kubeconfig"
```

It works unmodified because `server:` points at the VIP, which the host can reach.

### 5.4 Joining a worker

```bash
# on the control plane — prints a ready-to-paste command, token valid 24 h
sudo kubeadm token create --print-join-command
# kubeadm join 192.168.56.5:6443 --token <t> --discovery-token-ca-cert-hash sha256:<h>
```

```bash
# on the worker
sudo kubeadm join 192.168.56.5:6443 --token <t> --discovery-token-ca-cert-hash sha256:<h>
```

> ⚠️ **That printed line is exactly what this lab does *not* use.** It cannot carry
> `node-ip` (see 5.2), so a node joined this way registers with `10.0.2.15`. The repo renders
> a `JoinConfiguration` file instead — [`kubeadm-join-worker.yaml.tpl`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/templates/kubeadm-join-worker.yaml.tpl)
> — and runs `kubeadm join --config /vagrant/_out/join-<node>.yaml`. If you join by hand and
> then see every node with the same `INTERNAL-IP`, this is why.

### 5.5 Joining a second control plane

Two extra ingredients: the **certificate key**, which decrypts the `kubeadm-certs` Secret, and
`--control-plane`.

```bash
# on cp1 — re-encrypts the Secret and prints a NEW key on the last line
sudo kubeadm init phase upload-certs --upload-certs

# one-liner producing the complete join command
sudo kubeadm token create --print-join-command \
  --certificate-key "$(sudo kubeadm init phase upload-certs --upload-certs | tail -n1)"
```

```bash
# on cp2
sudo kubeadm join 192.168.56.5:6443 --token <t> --discovery-token-ca-cert-hash sha256:<h> \
  --control-plane --certificate-key <key>
```

> ⚠️ **The certificate key expires after 2 hours**, the token after 24. Both are cheap to
> regenerate (the two commands above); a stale one gives a decryption error that does not
> mention expiry at all.

> ⚠️ **`--config` and `--certificate-key` are mutually exclusive.** With a config file the key
> goes under `controlPlane.certificateKey` — *not* at the document root, unlike
> `InitConfiguration`. See [`kubeadm-join-cp.yaml.tpl`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/templates/kubeadm-join-cp.yaml.tpl).

> ⚠️ **Join control planes one at a time.** Each join adds an etcd member, and etcd accepts a
> single membership change at a time. Run two in parallel and the second fails with a quorum
> error that is hard to read and easy to misdiagnose.

### 5.6 Where this differs from older kubeadm notes

The repo grew out of a hand-written walkthrough
(`README-installkubeadm.md`, kept for archaeology). Four things in
notes of that vintage are no longer right:

| Old habit | What to do now |
|---|---|
| GPG key from the `v1.35` repo, `sources.list` pointing at `v1.34` | key and repo **must be the same minor**, and both must match `K8S_VERSION` — that mismatch is why the pair lives in `lab.env` |
| `apt-get install -y kubelet kubeadm kubectl` (unpinned) | pin the exact version (`kubelet=1.36.3-*`) then `apt-mark hold`: an accidental `apt upgrade` otherwise breaks the kubelet/apiserver skew |
| `apt-get install containerd` (Debian, 1.7.x) | containerd **2.x** from the Docker repo — 1.7 has no CRI `RuntimeConfig` and is a dead end (§9) |
| `sandbox_image = "registry.k8s.io/pause:3.10.2"` hard-coded | ask the tool: `kubeadm config images list` — and in containerd 2.x the key is `sandbox` under `[plugins.'io.containerd.cri.v1.images'.pinned_images]` |
| `kubeadm init --apiserver-advertise-address 192.168.56.10` (no VIP) | `--control-plane-endpoint <VIP>:6443` from the start, even with a single CP (§9) |

---

## 📦 6. What comes next: the application layer

A bare cluster does nothing useful — and here it is not even `Ready`. Everything else lives in
**[`_k8s/`](_k8s/README.md)**: Cilium, Envoy Gateway, cert-manager, metrics-server, Longhorn,
Vault, CloudNativePG, Prometheus/Loki, Kyverno, Trivy, MinIO, Argo CD…

```bash
./kubeadm/cluster-up.sh            # 1. the cluster (NotReady: no CNI yet)
./_k8s/platform-up.sh              # 2. CNI → Envoy Gateway → metrics-server → wildcard TLS
./_k8s/argocd/argocd-up.sh         # 3. opt-in addons
```

`platform-up.sh` installs the CNI first; the nodes go `Ready` within a minute or two of that
step. Full dependency chain and addon list: [`_k8s/README.md`](_k8s/README.md).

> ⚠️ **This layer assumes `CNI=cilium`** (the default). It needs a `LoadBalancer` Service that
> actually gets an IP, which on a host-only network only Cilium's L2/ARP announcement
> provides. With `calico`, `flannel` or `none` the Gateway stays at `EXTERNAL-IP <pending>`
> and no UI is reachable. Details in §10.

### 6.1 The two manual prerequisites

Nothing in the cluster can do these for you.

**a) Make `*.<LAB_DOMAIN>` resolve to the Gateway IP.** Every lab UI is served through one
entry point — Envoy's `LoadBalancer` Service, which takes the **first IP of `LB_POOL_START`**,
`192.168.56.200` by default. With `SELF_SIGNED=true` (the default) an `/etc/hosts` line on the
host is enough, and no public DNS record is needed:

```bash
kubectl -n envoy-gateway-system get svc -o wide | grep LoadBalancer   # the actual IP
# /etc/hosts
# 192.168.56.200  argo.kubeadm.lab.example.io grafana.kubeadm.lab.example.io
```

With `SELF_SIGNED=false` you need a real wildcard `A` record `*.<LAB_DOMAIN>` → the Gateway
IP, **DNS-only** (a CDN proxy cannot reach a private `192.168.56.x` origin).

**b) Choose the TLS mode**, with `SELF_SIGNED` in `lab.env`. `true`: `platform-up.sh` builds a
local CA and a wildcard certificate with `openssl`, installs no cert-manager, needs no token
and no public domain — the browser warns until you import `_out/self-signed/ca.crt`. `false`:
cert-manager + Let's Encrypt over ACME DNS-01, which requires a real domain,
`CLOUDFLARE_API_TOKEN`, and respect for the **5 certificates per week** production quota
(`LAB_ACME_ISSUER=staging` is the default for exactly that reason). Both paths fill the same
`wildcard-<LAB_DOMAIN with dashes>-tls` Secret, so no addon has to know which one you picked.

---

## ♻️ 7. Lifecycle

```bash
vagrant status                 # VM state
vagrant halt                   # power off (the cluster comes back on the next `up`)
vagrant up                     # power back on
vagrant destroy -f             # delete every VM
```

After a `destroy`, also clear the host-side state before rebuilding:

```bash
rm -rf _out kubeconfig
```

### 7.1 Growing the lab

`cluster-up.sh` is idempotent, and that *is* the procedure for adding nodes:

1. raise `WORKERS` (or `CONTROL_PLANES`, keeping it odd) in `lab.env`;
2. `vagrant up` — only the new VMs get created and provisioned;
3. `./kubeadm/cluster-up.sh` — it skips everything already in place and joins only the new
   nodes, with freshly generated credentials.

No certificate regeneration is needed: the `certSANs` already cover 5 control-plane IPs
(§5.2).

To remove a worker, drain it first so the cluster stops scheduling on a machine that is about
to vanish:

```bash
kubectl drain k8s-w3 --ignore-daemonsets --delete-emptydir-data
vagrant destroy -f k8s-w3
kubectl delete node k8s-w3
```
then lower `WORKERS` in `lab.env`.

### 7.2 Undoing the cluster without destroying the VMs

```bash
./kubeadm/cluster-reset.sh          # asks for confirmation
./kubeadm/cluster-reset.sh --yes    # unattended
```

It runs `kubeadm reset` on every node (**workers first**, so they deregister while the API
still answers), then removes `_out/` and `kubeconfig` on the host. The VMs keep running with
their packages, containerd and keepalived intact — a rebuild is then `./kubeadm/cluster-up.sh`
alone, minutes instead of a full `vagrant up`.

Prefer it to `vagrant destroy` when you want to **replay a failed bootstrap**, or to change
`POD_CIDR`, `SERVICE_CIDR`, the CNI or the VIP — all four are frozen at `kubeadm init` and
cannot be changed on a live cluster.

> ⚠️ **Destructive**: etcd, the certificates and every workload are lost, including anything
> in a PersistentVolume backed by a node's disk.

> ℹ️ **Why a dedicated reset and not just `kubeadm reset`**: `kubeadm reset` deliberately
> leaves behind what it did not create — CNI interfaces (`cilium_host`, `lxc*`, `flannel.1`,
> `cali*`), Cilium's **pinned eBPF programs under `/sys/fs/bpf`** (which survive the DaemonSet
> and keep intercepting traffic for a cluster that no longer exists), and kube-proxy's
> iptables/ipvs rules. [`node-reset.sh`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/node-reset.sh) cleans all of it; without that
> pass, the next `init` inherits a ghost datapath and the pod network misbehaves in ways no
> log explains.

---

## 🚑 8. Troubleshooting

Symptoms and fixes have their own page so this one stays about installing:
**[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)**. The four you are most likely to hit:

- **All nodes `NotReady`, CoreDNS `Pending`** → no CNI yet. Expected until
  `./_k8s/platform-up.sh` — kubeadm never installs one.
- **`cluster-up.sh` stops on "the apiserver does not answer on the VIP"** → either keepalived
  is not carrying the VIP (`vagrant ssh k8s-cp1 -c "ip -4 addr show | grep 192.168.56.5"`,
  `sudo systemctl status keepalived`), or the apiserver itself is not starting
  (`sudo crictl ps -a | grep apiserver`, `sudo journalctl -u kubelet -n 50`).
- **Every node shows the same `INTERNAL-IP` `10.0.2.15`** → a node joined without `node-ip`,
  i.e. with the printed `kubeadm join` line instead of the rendered `JoinConfiguration`
  (§5.4).
- **`vagrant up` dies on `VERR_VMX_IN_VMX_ROOT_MODE`** → the KVM module holds VT-x; unload it.
- **Gateway stuck at `EXTERNAL-IP <pending>`** → `CNI` is not `cilium`, so nothing announces
  LoadBalancer IPs on the host-only network (§10).

Addon-specific problems live in the ⚠️ pitfalls and 🚑 troubleshooting sections of each
`_k8s/<addon>/README.md` — index in [`_k8s/README.md`](_k8s/README.md).

---

## 🔍 9. How it works (under the hood)

### 9.1 The VIP is carried by keepalived, not by kube-vip

This is the most structural decision in the repo.

`controlPlaneEndpoint` points at the VIP, and it is **frozen into the certificates and into
every kubeconfig at `kubeadm init` time**. The VIP must therefore exist *before* the init.

kube-vip, the usual answer in kubeadm HA guides, runs as a static pod and elects its leader
**through the Kubernetes API** — that is, through the very VIP it is supposed to carry.
Chicken and egg. The documented way out is to point it at
`--k8sConfigPath /etc/kubernetes/super-admin.conf`, itself fragile since Kubernetes 1.29 moved
`admin.conf` out of the `system:masters` group ([kube-vip#684](https://github.com/kube-vip/kube-vip/issues/684),
still open).

keepalived has none of that: it is a plain VRRP daemon, it knows nothing about Kubernetes, it
brings the VIP up at VM boot, and the circular dependency disappears. Its configuration is
written by [`provision.sh`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/provision.sh):

- **Unicast VRRP** (`unicast_src_ip` + `unicast_peer`), not multicast: on a VirtualBox
  host-only switch multicast is the first thing to behave strangely, and we know every
  control-plane IP anyway.
- **Priorities** cp1 = 100, cp2 = 90, cp3 = 80.
- **`vrrp_script chk_apiserver`** polls `https://127.0.0.1:6443/livez` every 3 s with
  `weight -30`: a control plane whose apiserver is dead drops to 70 and falls behind a healthy
  cp2 at 90, which takes the VIP over.
- `/livez` is readable **anonymously** thanks to the `system:public-info-viewer`
  ClusterRoleBinding kubeadm creates — no credential to distribute to a health script.
- **While no cluster exists, the check fails on every CP**: they each lose 30 points, the
  relative order is preserved, and the VIP is carried anyway. Which is exactly what
  `kubeadm init` needs.
- **No `authentication` block**: VRRPv2 sends its password in clear text and buys nothing. The
  trust boundary here is the host-only network. To coexist with another keepalived lab on the
  same network, change `VRRP_ROUTER_ID`.

> ℹ️ kube-vip remains a perfectly good option **once the cluster is running** (`--services`
> mode, for LoadBalancer Services). It is the *bootstrap* role that does not work out here.

### 9.2 The VIP is used even with a single control plane

Because `controlPlaneEndpoint` is frozen at `init`. Pointing it at the VIP from the very first
run makes going from 1 to 3 control planes a plain `join`; pointing it at cp1's real IP would
mean regenerating every certificate and redistributing every kubeconfig.

### 9.3 containerd 2.x from the Docker repo, not the Debian package

Debian 13 ships containerd **1.7.24**. Only the 2.x branch implements the CRI `RuntimeConfig`
method, which kubeadm uses to read the runtime's cgroup driver. On 1.36 its absence is a
preflight **warning**; the fallback disappears in **1.37**, and the backport to the 1.7 branch
was **refused** ([containerd#11346](https://github.com/containerd/containerd/issues/11346),
closed without merge). 1.7 is a dead end. `CONTAINERD_SOURCE=debian` stays available for an
offline lab.

`SystemdCgroup = true` matters more than the kubelet's `cgroupDriver` field: Debian 13 is
cgroup v2 with systemd as the manager, and leaving containerd on `cgroupfs` puts two managers
on the same hierarchy — nodes then get unstable under load.

> ⚠️ **The 1.7 → 2.x migration trap**: the `pause` image key changed *name and location*.
> Config v2 has `sandbox_image = "..."` under `[plugins."io.containerd.grpc.v1.cri"]`; config
> v3 has `sandbox = '...'` under `[plugins.'io.containerd.cri.v1.images'.pinned_images]`. A
> config copied over as-is silently loses the setting. `provision.sh` regenerates the file
> from `containerd config default` on every run and patches whichever key is present.

> ℹ️ The `pause` tag itself is **never hard-coded**: it comes from
> `kubeadm config images list`. A mismatch between containerd's pause and kubeadm's is
> invisible while you are online (it just re-pulls) and fatal offline.

### 9.4 `node-ip` forced on every node

The number-one trap of any Vagrant-based Kubernetes lab, described in
§5.2: the NAT NIC is `10.0.2.15` on every VM.
Because neither `kubeadm init` nor `kubeadm join` has a flag for it, the lab drives both from
`InitConfiguration`/`JoinConfiguration` files carrying
`nodeRegistration.kubeletExtraArgs: [{name: node-ip, value: <host-only IP>}]`.

### 9.5 kubeadm API `v1beta4`

Current and default since Kubernetes 1.31; `v1beta3` is deprecated.

> ⚠️ **The breaking change to know**: `extraArgs` and `kubeletExtraArgs` are no longer
> **maps** but **lists of `{name, value}`** — so a flag can be repeated. Any file written
> before 1.31 is invalid as-is, and the error kubeadm returns does not point at the shape.
> ```yaml
> # v1beta3:  extraArgs: {bind-address: "0.0.0.0"}
> # v1beta4:  extraArgs: [{name: bind-address, value: "0.0.0.0"}]
> ```
> `make validate-kubeadm` catches exactly this, in CI, without a cluster.

### 9.6 The `/vagrant` synced folder is a mechanism, not a convenience

`cluster-up.sh` does **nothing inside the VMs itself**. It renders the kubeadm configurations
into `_out/` on the host, then calls [`node-init.sh`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/node-init.sh) and
[`node-join.sh`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/node-join.sh) through `vagrant ssh`; the VMs read those files at
`/vagrant/_out/`. No `scp`, no secret passed on a command line (where it would land in shell
history and process listings), and the logic stays in versioned files you can read in a diff
instead of in an escaping nightmare inside `vagrant ssh -c`.

> ⚠️ `_out/join.env` holds the **bootstrap token and the certificate key**. The directory is
> gitignored, but it is readable from every VM through the synced folder. It is a lab: fine
> here, not a pattern to carry into production.

### 9.7 What kubeadm does not do, and `cluster-up.sh` does

- **Worker roles**: kubeadm sets no role label, so `kubectl get nodes` shows `<none>` under
  ROLES and `node-role.kubernetes.io/worker` selectors match nothing. `cluster-up.sh` applies
  the label.
- **Control-plane taint**: `UNTAINT_CP=auto` removes it only when `WORKERS=0` — otherwise
  nothing could be scheduled anywhere. That is what makes a 1-VM lab usable.
- **Control-plane metrics**: `controllerManager` and `scheduler` get `bind-address: 0.0.0.0`;
  by default they listen on loopback only and Prometheus shows two DOWN targets with no
  explanation. Acceptable because the host-only network is isolated.
- **Pre-pulled images**: done during `vagrant up`, in parallel across VMs, so `kubeadm init`
  downloads nothing — the single biggest source of bootstrap timeouts. Workers only pull
  `pause` and `kube-proxy`, saving ~500 MiB each.
- **Swap**: turned off and masked (including systemd swap units, which `/etc/fstab` does not
  describe). NodeSwap is GA since 1.34 but `failSwapOn` still defaults to true.

---

## 🌐 10. CNI: Cilium, Calico or Flannel

**kubeadm installs no CNI, ever.** Unlike the Talos twin repo — where flannel can be laid down
by the OS at bootstrap — here the pod network is *always* installed afterwards, by
`_k8s/platform-up.sh`. `CNI` in `lab.env` is read by `cluster-up.sh` (for the kube-proxy
decision and `_out/cluster.env`) and by `platform-up.sh` (which chart to install).

| `CNI=` | Who installs it | `LoadBalancer` IP | `_k8s/` layer usable |
|---|---|---|---|
| **`cilium`** *(default)* | `platform-up.sh` → [`_k8s/cilium/`](_k8s/cilium/README.md) | ✅ pool + L2/ARP announcement | ✅ yes |
| `calico` | `platform-up.sh` → [`_k8s/calico/`](_k8s/calico/README.md) | ❌ BGP only | ⚠️ needs MetalLB on top |
| `flannel` | `platform-up.sh` | ❌ | ❌ no |
| `none` | you | ❌ | depends on what you install |

**In practice: keep `cilium`.** It is the only value that makes the lab work end to end,
because it is the only one that gives Services an `EXTERNAL-IP` on a host-only network — and
therefore the only one that gets you the HTTPS UIs. `calico` is there to compare CNIs and work
on `NetworkPolicy`; `flannel` for a deliberately bare cluster.

> ⚠️ **`KUBE_PROXY_REPLACEMENT=true` requires `CNI=cilium`**, and `cluster-up.sh` refuses to
> start with any other combination. With `--skip-phases=addon/kube-proxy` and no replacement,
> **no ClusterIP answers at all** — not even CoreDNS reaching the API. The error message
> offers the two ways out: `CNI=cilium`, or `KUBE_PROXY_REPLACEMENT=false`.

> ℹ️ **Why Cilium needs `k8sServiceHost`/`k8sServicePort`** when kube-proxy is gone: nothing
> provisions the apiserver's ClusterIP, so the agent cannot bootstrap through
> `kubernetes.default`. The lab points it at the **VIP** — which also means the agents survive
> the loss of any single control plane.

> ℹ️ The lab uses the `--skip-phases=addon/kube-proxy` flag rather than v1beta4's declarative
> `proxy.disabled` field: identical result, but the flag is battle-tested across versions and
> is the one Cilium's own documentation uses.

> ⚠️ **`POD_CIDR` must be the CIDR the CNI really announces.** Cilium in `cluster-pool` mode
> defaults to `10.0.0.0/8`, unrelated to what kubeadm was told; `_k8s/cilium/cilium-up.sh`
> passes `POD_CIDR` back to it explicitly. Two divergent values give you a broken pod network
> that looks configured.

> ⚠️ **Switching CNI on an existing cluster is not supported.** `./kubeadm/cluster-reset.sh`
> (or `vagrant destroy`) first — two CNIs fight over the pod network, and the leftover
> datapath is exactly what `node-reset.sh` exists to clean.

---

## 🛠️ 11. Validating a change

Everything can be validated **without booting a cluster**:

```bash
make validate       # shell + YAML + Vagrantfile + kubeadm templates + doc links
make docs           # regenerates docs/index.html from every README (EN + FR)
make help           # lists the targets
```

| Target | What it covers |
|---|---|
| `validate-shell` | `bash -n` on every `*.sh` tracked by git |
| `validate-yaml` | parses every `*.yaml` / `*.yml` tracked by git (PyYAML, fetched by `uv`) |
| `validate-vagrant` | `vagrant validate`; locally it also checks the provider config |
| `validate-defaults` | asserts that the fallback defaults in the `Vagrantfile` and in `cluster-up.sh` still match `lab.env.example`, key by key |
| `validate-kubeadm` | renders the 3 templates with dummy values in a throwaway dir, parses them, then runs `kubeadm config validate` **if `kubeadm` is in your PATH** |
| `validate-docs` | builds the docs into a throwaway file and fails on any dead `*.md` link or unknown cross-page anchor |

`validate-kubeadm` is the one with the most value: it is what catches a real v1beta4 schema
error — a `extraArgs` left in v1beta3 map form — instead of discovering it ten minutes into a
`vagrant up`. On CI, where `kubeadm` is installed for the job, the schema check always runs.

**On every pull request** the `ci` workflow re-runs shell, defaults, YAML, kubeadm and
Vagrantfile validation by calling the very same `make` targets, so a check cannot pass in CI
and fail on your machine. It also asserts that the guard actually fires: `CONTROL_PLANES=2 vagrant
validate` **must** be rejected. `vagrant validate` runs there with `--ignore-provider`, since a
runner has no VirtualBox; `validate-docs` is covered by the `docs` workflow.

> ℹ️ Nothing in the `Makefile` touches a running cluster, and nothing regenerates secrets.
> `make validate` is safe on a lab that is up.

---

## 📄 12. License

This project is licensed under the **Apache License 2.0** — see
[`LICENSE`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/LICENSE).

In short: use it, modify it, redistribute it, including commercially, as long as you keep the
copyright notice and state your changes. It comes with **no warranty**: this is a lab, do not
run it in production.

The license covers what this repo actually contains — the `Vagrantfile`, the `kubeadm/` and
`_k8s/` scripts, the templates, the manifests and the documentation. It does **not** extend to
the third-party components those scripts download (Kubernetes, containerd, keepalived, Cilium,
Envoy Gateway, Longhorn, Vault…), each of which keeps its own license.
