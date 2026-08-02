<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🏠 ☸️ Vagrant-KubeADM

> **Kubernetes 1.36 the hard way — `kubeadm` on Debian 13 VMs, on VirtualBox.** `vagrant up`
> prepares the machines, one script chains the `kubeadm` commands, and a full application layer
> (Cilium, Envoy Gateway, Longhorn, Vault, PostgreSQL…) comes on top. Single control plane, or
> HA with 3 CPs behind a keepalived VIP.

Every VM is an ordinary Debian box with SSH and `apt`, and every step the scripts take is a
`kubeadm` command you could type yourself — §5 shows exactly which ones. What the repo adds is
the error-prone part: the VIP that must exist *before* `kubeadm init`, the `node-ip` every
Vagrant lab gets wrong, the containerd 2.x config, the certificate SANs you cannot add later.

```bash
git clone --recurse-submodules https://github.com/OPS-NC/Vagrant-kubeadm.git
cd Vagrant-kubeadm
cp lab.env.example lab.env      # pick the topology
vagrant up                      # creates and PREPARES the VMs (no cluster yet)
./kubeadm/cluster-up.sh         # kubeadm init + join + kubeconfig
./_k8s/platform-up.sh           # CNI, Envoy Gateway, metrics-server, wildcard TLS
```

| | |
|---|---|
| 📖 **Browsable docs** | [ops-nc.github.io/Vagrant-kubeadm](https://ops-nc.github.io/Vagrant-kubeadm/) — EN/FR, light/dark, offline copy with `make docs` |
| 📦 **Application layer** | [ops-nc.github.io/k8s-playground](https://ops-nc.github.io/k8s-playground/) — its own repo, mounted here as the `_k8s/` submodule |
| ⬆️ **Kubernetes upgrades** | [`kubeadm/UPGRADE.md`](kubeadm/UPGRADE.md) |
| 🚑 **Something broken?** | [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) |

> ⚠️ **`--recurse-submodules` is not optional.** `_k8s/` is a git submodule; a plain `git clone`
> leaves it **empty** and `./_k8s/platform-up.sh` returns `No such file or directory`. On a clone
> already made: `git submodule update --init --recursive`.

> ℹ️ **There is a twin lab, [Vagrant-Talos](https://github.com/OPS-NC/Vagrant-Talos)** — same IP
> plan, same application layer, opposite operating model: Talos is immutable, has no SSH and no
> package manager, and is driven entirely through an API. Here you get a normal distribution and
> you drive `kubeadm` yourself: more moving parts, which is what makes the lab worth reading.

---

## 🧰 1. Prerequisites (on the host)

| Tool | Purpose | Install |
|---|---|---|
| VirtualBox 7 | hypervisor | https://www.virtualbox.org/ |
| Vagrant | VM creation | https://developer.hashicorp.com/vagrant |
| `git` | the repo **and its `_k8s/` submodule** | https://git-scm.com/ |
| `kubectl` | using the cluster | https://kubernetes.io/docs/tasks/tools/ |
| `helm` | `_k8s/` addons | https://helm.sh/docs/intro/install/ |
| `uv` *(optional)* | `make docs` | https://docs.astral.sh/uv/ |

That is the whole list — no cluster-specific binary on your machine. `kubeadm`, `kubelet`,
`kubectl` and `containerd` live *inside* the VMs, installed by
[`kubeadm/provision.sh`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/provision.sh)
during `vagrant up`. The `bento/debian-13` box is downloaded by Vagrant on first use; no plugin
required.

Managing the submodule:

```bash
git submodule update --init --recursive     # fills _k8s/ on an existing clone
git submodule update --remote _k8s          # move it to the latest upstream commit
```

> ⚠️ **`git pull` does not update the submodule.** It moves *this* repo only, leaving `_k8s/` on
> the commit pinned before — you would run the documented commands against an older application
> layer. `git status` showing `modified: _k8s (new commits)` just means the checkout no longer
> matches the pin.

> ⚠️ **VirtualBox and KVM cannot share VT-x.** With the KVM module loaded, `vagrant up` dies on
> `VERR_VMX_IN_VMX_ROOT_MODE`. Unload it first (`sudo modprobe -r kvm_intel kvm`, or `kvm_amd`)
> — see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

> 💡 Keep host `kubectl` within one minor of the cluster (1.35 → 1.37 for a 1.36 cluster), or
> fall back to the in-VM one: `vagrant ssh k8s-cp1 -c 'kubectl get nodes -o wide'`.

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

Pod network `10.244.0.0/16`, Service network `10.96.0.0/12`. Node IPs are **static**, assigned by
the `Vagrantfile`; it refuses a node IP landing on `.1`, `.2`, `.100` or on the VIP, and refuses
duplicates.

Every VM has **2 NICs**: NIC1 = VirtualBox NAT (Internet, `10.0.2.15` on *every* VM) and NIC2 =
host-only `192.168.56.x` (cluster, API, etcd, pods). The default route goes through the NAT so
the VMs can reach `apt` and the registries; what must be host-only is the node's *identity*,
never its default route — see `node-ip` in §8.

> ℹ️ **The host-only interface name is never hard-coded.** Debian 13 usually names it `enp0s8`,
> some box builds still give `eth1`. `provision.sh` finds the interface carrying the node's IP,
> writes it to `/etc/kubeadm-lab/node.env`, and `cluster-up.sh` copies it into `_out/cluster.env`
> as `HOSTONLY_IF`. keepalived binds VRRP to it and Cilium announces LoadBalancer IPs on it.

> ℹ️ Name resolution depends on neither DNS nor boot order: the `Vagrantfile` pushes an identical
> `/etc/hosts` block to every node, and `provision.sh` deletes Debian's `127.0.1.1 <hostname>`
> line — left in place, the kubelet resolves its own name to loopback and the node registers as
> unreachable.

---

## ⚙️ 3. Pick the topology — `lab.env`

`lab.env` is the single source read by the `Vagrantfile`, by `kubeadm/cluster-up.sh` and by the
`_k8s/*-up.sh` scripts. Copy the versioned template (`lab.env` itself is gitignored):

```bash
cp lab.env.example lab.env
```

Format is strict: one `KEY=value` per line, no spaces around `=`. A real environment variable
always wins, so one-off overrides work: `WORKERS=5 vagrant up`.

| Variable | Default | Purpose |
|---|---|---|
| `K8S_VERSION` | `1.36.3` | version installed (`kubelet`/`kubeadm`/`kubectl`, pinned then `apt-mark hold`) |
| `K8S_APT_MINOR` | `v1.36` | `pkgs.k8s.io` repository minor — **must match `K8S_VERSION`** |
| `CONTAINERD_SOURCE` | `docker` | `docker` → containerd 2.x · `debian` → containerd 1.7 (§8) |
| `SYSTEM_UPGRADE` | `true` | full `apt-get upgrade` per VM; `false` roughly halves `vagrant up` |
| `REGISTRY_MIRROR` | *(empty)* | pull-through mirror → `/etc/containerd/certs.d/docker.io/hosts.toml` |
| `CONTROL_PLANES` | `1` | `1` = single, `3` = HA. **Even numbers are refused** |
| `WORKERS` | `2` | number of workers; `0` is valid (see `UNTAINT_CP`) |
| `CP_MEM` / `CP_CPU` | `3072` / `2` | control plane resources — **never below `3072`**: etcd |
| `WK_MEM` / `WK_CPU` | `2048` / `2` | worker resources |
| `BOX` | `bento/debian-13` | the lab is written and tested for Debian 13 |
| `NODE_PREFIX` | `k8s` | VM/node names: `k8s-cp1`, `k8s-w1`… |
| `CLUSTER_NAME` | `kubeadm-lab` | kubeadm `clusterName` + kubeconfig context |
| `NETWORK` | `192.168.56` | host-only network (first 3 octets) |
| `VIP` | `192.168.56.5` | API VIP = `controlPlaneEndpoint`, carried by keepalived |
| `CP_IP_START` / `CP_IP_STEP` | `10` / `10` | → `.10`, `.20`, `.30` |
| `WK_IP_START` / `WK_IP_STEP` | `101` / `1` | → `.101`, `.102`, `.103` |
| `POD_CIDR` | `10.244.0.0/16` | kubeadm `podSubnet` — **the CNI must announce the same one** |
| `SERVICE_CIDR` | `10.96.0.0/12` | kubeadm `serviceSubnet` |
| `LB_POOL_START` / `LB_POOL_END` | `192.168.56.200` / `.230` | `LoadBalancer` range; **the 1st is the Gateway's** |
| `VRRP_ROUTER_ID` | `51` | keepalived VRRP group (1-255) — change it to coexist with another keepalived lab |
| `CNI` | `cilium` | `cilium`, `calico`, `flannel` or `none` (§9) |
| `CILIUM_VERSION` | `1.20.0` | Cilium chart version (ignored unless `CNI=cilium`) |
| `KUBE_PROXY_REPLACEMENT` | `true` | eBPF replacement of kube-proxy — **requires `CNI=cilium`** |
| `UNTAINT_CP` | `auto` | remove the control-plane taint: `auto` (only if `WORKERS=0`), `true`, `false` |
| `LAB_DOMAIN` | `kubeadm.lab.example.io` | UI domain (`*.<domain>`: wildcard TLS + `HTTPRoute`) |
| `SELF_SIGNED` | `true` | `true` = wildcard signed by a local CA (`openssl`) · `false` = cert-manager + Let's Encrypt |
| `LAB_DNS_ZONE` | *(empty → last 2 labels)* | DNS zone of the ACME DNS-01 solver — `SELF_SIGNED=false` only |
| `LAB_ACME_EMAIL` | *(empty → `admin@<zone>`)* | Let's Encrypt account — `SELF_SIGNED=false` only |
| `LAB_ACME_ISSUER` | `staging` | `staging` (untrusted, huge quota) or `prod` (trusted, **5 certs/week**) |
| `CLOUDFLARE_API_TOKEN` | *(empty)* | cert-manager DNS-01 — `SELF_SIGNED=false` only, and **never** in the template |

Two more are read by `cluster-up.sh` without being in the template: `OUT` (`_out`) and `WAIT_API`
(`600`, seconds to wait for the apiserver on the VIP).

**What each topology costs.** Default (1 CP + 2 workers): **7 GB of RAM**, 6 vCPU. Full HA
(`CONTROL_PLANES=3`, `WORKERS=3`): 3 × 3072 + 3 × 2048 = **15.4 GB**, 12 vCPU. Disks are linked
clones, so the box is stored roughly once.

Three constraints worth knowing before you edit:

- **Control planes must be odd** — the `Vagrantfile` and `cluster-up.sh` both refuse an even
  number. etcd holds quorum at `(n/2)+1`: 2 members cost twice one CP and tolerate zero failures.
- **`CP_MEM` ≥ 3072.** kubeadm's preflight demands ~1700 MiB, so 2048 passes and then starves the
  stacked etcd as soon as addons pile up. `_k8s/observability/` wants `4096`.
- **`K8S_VERSION` and `K8S_APT_MINOR` must agree.** `pkgs.k8s.io` repositories are per-minor, and
  a mismatch fails in `apt` with an error that never mentions it. That pair is what you bump for
  an upgrade — [`kubeadm/UPGRADE.md`](kubeadm/UPGRADE.md).

---

## 🚀 4. Start the cluster

```bash
vagrant up                      # VMs + packages + containerd + kubeadm + keepalived
./kubeadm/cluster-up.sh         # init + joins + kubeconfig
```

**`vagrant up` bootstraps nothing.** It creates the VMs and runs `provision.sh` in each, which
lays down, in order: `/etc/hosts` · swap off + kernel modules + sysctl · base packages
(`conntrack`, `socat`, `ethtool`, `open-iscsi`, `nfs-common`…) · containerd with
`SystemdCgroup = true` · `kubelet`/`kubeadm`/`kubectl` pinned and held · **pre-pulled images** ·
and, on control planes, **keepalived carrying the VIP**. Each VM ends ready to receive a
`kubeadm init` or `join`, and nothing more.

`cluster-up.sh` then prints five steps:

| Step | What happens |
|---|---|
| `[1/5]` | renders the kubeadm configs into `_out/` **on the host**, from [`kubeadm/templates/`](https://github.com/OPS-NC/Vagrant-kubeadm/tree/main/kubeadm/templates) |
| `[2/5]` | `kubeadm init` on the 1st CP; copies `admin.conf` to `./kubeconfig`; **waits for `https://<VIP>:6443/readyz`** |
| `[3/5]` | joins the secondary control planes, **one at a time** (etcd accepts one membership change at a time) |
| `[4/5]` | joins the workers |
| `[5/5]` | untaints per `UNTAINT_CP`, labels the workers, writes `_out/cluster.env` (detected `HOSTONLY_IF` included) |

Before touching anything it validates the config and checks that **all** expected VMs are
`running` — cheap up front, versus a `vagrant ssh` timing out mid-`join`.

```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide
```

The kubeconfig needs no editing: its `server:` is the VIP, reachable from the host.

> ⚠️ **The nodes will be `NotReady`, and that is normal.** kubeadm never installs a CNI. Until a
> pod network exists the kubelet reports `cni plugin not initialized`, CoreDNS stays `Pending`
> and the nodes stay `NotReady`. The fix is the next command: `./_k8s/platform-up.sh` (§6).

> 💡 **`cluster-up.sh` is idempotent** — `node-init.sh` refuses to re-run `kubeadm init` if
> `/etc/kubernetes/admin.conf` exists, `node-join.sh` skips a node that already has
> `kubelet.conf`. Re-running it is also how you grow the lab (§7.1). Join credentials are
> regenerated on **every** run, because the bootstrap token expires after 24 h and the
> certificate key after 2 h — so a run three days later just works.

For another topology, edit `lab.env`, or override on the spot **for both commands**, since each
re-reads its own environment:

```bash
CONTROL_PLANES=3 WORKERS=3 vagrant up
CONTROL_PLANES=3 WORKERS=3 ./kubeadm/cluster-up.sh
```

---

## 🎓 5. Doing it by hand

This is what the lab is for. The scripts exist so you do not retype these commands at every
rebuild, not to hide them. Below is the same path by hand, on a lab that has been `vagrant up`-ed.

### 5.1 What `vagrant up` already left you

```bash
vagrant ssh k8s-cp1
sudo -i
kubeadm version -o short                 # v1.36.3, held by apt-mark
containerd --version                     # 2.x when CONTAINERD_SOURCE=docker
crictl ps                                # talks to /run/containerd/containerd.sock
ip -4 addr show | grep 192.168.56.5      # the VIP is ALREADY there, before any init
cat /etc/kubeadm-lab/node.env            # NODE_IP, HOSTONLY_IF, VIP…
```

The VIP being up **before** `kubeadm init` is the whole reason keepalived is used here rather
than kube-vip (§8.1).

### 5.2 `kubeadm init` on the first control plane

The repo's way — `cluster-up.sh` already rendered the config into `_out/`, visible from the VM
through the synced folder:

```bash
sudo kubeadm init --config /vagrant/_out/kubeadm-init.yaml --upload-certs \
     --skip-phases=addon/kube-proxy          # only when KUBE_PROXY_REPLACEMENT=true
```

The flag-only equivalent, to see it without a config file:

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

The two addresses are not the same thing: `--apiserver-advertise-address` is the *real* IP this
apiserver listens on, `--control-plane-endpoint` is the *shared* VIP baked into the certificates
and into every kubeconfig.

> ⚠️ **The flag form cannot set `node-ip`, which is why the repo uses `--config`.** With flags
> alone the kubelet picks the default-route NIC — the NAT, `10.0.2.15`, **identical on every
> VM**. Every node then registers with the same address: `kubectl get nodes -o wide` looks
> plausible while logs, `exec`, probes and inter-node traffic go to the wrong place. The setting
> only exists as `nodeRegistration.kubeletExtraArgs`.

Two more things that cannot be fixed afterwards: **`--upload-certs`** stores the cluster CAs in
the `kubeadm-certs` Secret (without it, a second control plane can only join after you copy
`/etc/kubernetes/pki` by hand), and **certSANs**, which need regenerating the API certificate to
change — hence the 5 control-plane IPs declared up front, including nodes that do not exist yet.

### 5.3 Joining nodes

```bash
# on the control plane — prints a ready-to-paste command, token valid 24 h
sudo kubeadm token create --print-join-command
# on the worker
sudo kubeadm join 192.168.56.5:6443 --token <t> --discovery-token-ca-cert-hash sha256:<h>
```

A second control plane needs two more ingredients: `--control-plane` and the **certificate key**,
which decrypts the `kubeadm-certs` Secret.

```bash
# on cp1 — re-encrypts the Secret and prints a NEW key on the last line
sudo kubeadm token create --print-join-command \
  --certificate-key "$(sudo kubeadm init phase upload-certs --upload-certs | tail -n1)"
```

Four things bite here:

- **That printed join line is exactly what this lab does *not* use.** It cannot carry `node-ip`
  (§5.2), so a node joined this way registers with `10.0.2.15`. The repo renders a
  `JoinConfiguration` file instead and runs `kubeadm join --config /vagrant/_out/join-<node>.yaml`.
  Every node sharing one `INTERNAL-IP` is this, every time.
- **The certificate key expires after 2 hours**, the token after 24. Both are cheap to regenerate;
  a stale one gives a decryption error that never mentions expiry.
- **`--config` and `--certificate-key` are mutually exclusive.** With a config file the key goes
  under `controlPlane.certificateKey` — *not* at the document root, unlike `InitConfiguration`.
- **Join control planes one at a time.** Each join adds an etcd member, and etcd accepts a single
  membership change at a time; two in parallel fail on an unreadable quorum error.

Getting a kubeconfig needs no `scp` — the synced folder is right there, and `server:` already
points at the VIP:

```bash
vagrant ssh k8s-cp1 -c 'sudo cat /etc/kubernetes/admin.conf' > kubeconfig
chmod 0600 kubeconfig && export KUBECONFIG="$PWD/kubeconfig"
```

---

## 📦 6. What comes next: the application layer

A bare cluster does nothing useful — here it is not even `Ready`. Cilium, Envoy Gateway,
cert-manager, metrics-server, Longhorn, Vault, CloudNativePG, Prometheus/Loki, Kyverno, Trivy,
MinIO, Argo CD… all come from [k8s-playground](https://github.com/OPS-NC/k8s-playground), mounted
here as `_k8s/` and shared with the Talos twin. Its documentation is published separately:
**<https://ops-nc.github.io/k8s-playground/>**.

```bash
./_k8s/platform-up.sh                       # CNI → Envoy Gateway → metrics-server → TLS
./_k8s/install.sh longhorn vault argocd     # opt-in addons
./_k8s/install.sh list                      # the full catalogue
./_k8s/install.sh all                       # platform + every addon, in dependency order
./_k8s/longhorn/longhorn-up.sh              # one addon on its own
```

Nothing to declare: the **lab** is the directory containing `_k8s/` that carries the
`Vagrantfile` (so `lab.env`, `_out/` and `kubeconfig` are found there), and the **distribution**
is read off its contents — a `kubeadm/cluster-up.sh` next to the `Vagrantfile` means the kubeadm
lab. That works straight from the clone, before any `vagrant up`. An explicit
`./_k8s/install.sh kubeadm platform`, `--distro=kubeadm` or `K8S_DISTRO` still wins, and
`LAB_DIR` is the escape hatch for an unusual layout — neither is needed here.

`platform-up.sh` installs the CNI first; the nodes go `Ready` a minute or two later.

> ⚠️ **This layer assumes `CNI=cilium`** (the default). It needs a `LoadBalancer` Service that
> really gets an IP, which on a host-only network only Cilium's L2/ARP announcement provides —
> otherwise the Gateway stays at `EXTERNAL-IP <pending>` and no UI is reachable. See §9.

### 6.1 The two manual prerequisites

Nothing in the cluster can do these for you.

**a) Make `*.<LAB_DOMAIN>` resolve to the Gateway IP.** Every lab UI is served through Envoy's
`LoadBalancer` Service, which takes the first IP of `LB_POOL_START` — `192.168.56.200` by
default. With `SELF_SIGNED=true` an `/etc/hosts` line is enough and no public record is needed:

```bash
kubectl -n envoy-gateway-system get svc -o wide | grep LoadBalancer   # the actual IP
# /etc/hosts
# 192.168.56.200  argo.kubeadm.lab.example.io grafana.kubeadm.lab.example.io
```

With `SELF_SIGNED=false` you need a real wildcard `A` record `*.<LAB_DOMAIN>` → the Gateway IP,
**DNS-only** (a CDN proxy cannot reach a private `192.168.56.x` origin).

**b) Choose the TLS mode** with `SELF_SIGNED`. `true`: `platform-up.sh` builds a local CA and a
wildcard with `openssl` — no cert-manager, no token, no public domain, and a browser warning
until you import `_out/self-signed/ca.crt`. `false`: cert-manager + Let's Encrypt over ACME
DNS-01, which needs a real domain, `CLOUDFLARE_API_TOKEN`, and respect for the **5 certificates
per week** production quota (`LAB_ACME_ISSUER=staging` is the default for that reason). Both
paths fill the same `wildcard-<LAB_DOMAIN with dashes>-tls` Secret, so no addon has to know which
one you picked.

---

## ♻️ 7. Lifecycle

```bash
vagrant status                 # VM state
vagrant halt                   # power off (the cluster comes back on the next `up`)
vagrant up                     # power back on
vagrant destroy -f             # delete every VM
rm -rf _out kubeconfig         # clear host-side state before rebuilding
```

Keeping the repo current takes **two** commands, since `git pull` leaves `_k8s/` where it was:

```bash
git pull
git submodule update --init --recursive   # _k8s/ back onto the commit this repo pins
git submodule update --remote _k8s        # or: jump to the latest k8s-playground
```

### 7.1 Growing the lab

`cluster-up.sh` being idempotent *is* the procedure:

1. raise `WORKERS` (or `CONTROL_PLANES`, keeping it odd) in `lab.env`;
2. `vagrant up` — only the new VMs get created and provisioned;
3. `./kubeadm/cluster-up.sh` — skips what is in place, joins the new nodes with fresh credentials.

No certificate regeneration: the `certSANs` already cover 5 control-plane IPs (§5.2).

Removing a worker — drain first, so the cluster stops scheduling onto a machine about to vanish:

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

It runs `kubeadm reset` on every node (**workers first**, so they deregister while the API still
answers), then removes `_out/` and `kubeconfig`. The VMs keep their packages, containerd and
keepalived, so a rebuild is `./kubeadm/cluster-up.sh` alone — minutes instead of a full
`vagrant up`. Prefer it to `vagrant destroy` to replay a failed bootstrap, or to change
`POD_CIDR`, `SERVICE_CIDR`, the CNI or the VIP: all four are frozen at `kubeadm init`.

> ⚠️ **Destructive**: etcd, the certificates and every workload are lost, PersistentVolumes on
> node disks included.

> ℹ️ **Why a dedicated reset.** `kubeadm reset` deliberately leaves behind what it did not
> create — CNI interfaces, Cilium's **pinned eBPF programs under `/sys/fs/bpf`** (which survive
> the DaemonSet and keep intercepting traffic for a cluster that no longer exists), and
> kube-proxy's iptables rules. `node-reset.sh` cleans all of it; without that pass the next
> `init` inherits a ghost datapath and the pod network misbehaves with nothing in any log.

---

## 🔍 8. Design notes

### 8.1 The VIP is carried by keepalived, not kube-vip

The most structural decision in the repo. `controlPlaneEndpoint` points at the VIP and is
**frozen into the certificates and every kubeconfig at `kubeadm init` time**, so the VIP must
exist *before* the init.

kube-vip, the usual answer in kubeadm HA guides, runs as a static pod and elects its leader
**through the Kubernetes API** — that is, through the very VIP it is supposed to carry. The
documented way out is `--k8sConfigPath /etc/kubernetes/super-admin.conf`, itself fragile since
Kubernetes 1.29 moved `admin.conf` out of `system:masters`
([kube-vip#684](https://github.com/kube-vip/kube-vip/issues/684), still open).

keepalived has none of that: a plain VRRP daemon, knows nothing about Kubernetes, brings the VIP
up at VM boot. `provision.sh` configures it with **unicast VRRP** (multicast is the first thing to
misbehave on a VirtualBox host-only switch, and every control-plane IP is known anyway),
priorities cp1 = 100 / cp2 = 90 / cp3 = 80, and a `vrrp_script` polling
`https://127.0.0.1:6443/livez/ping` every 3 s with `weight -30` — so a CP whose apiserver is dead
drops to 70 and a healthy cp2 at 90 takes over. `/livez/ping` is readable anonymously via the
`system:public-info-viewer` binding kubeadm creates, so no credential has to reach a health
script. There is no `authentication` block: VRRPv2 sends its password in clear text and buys
nothing here, the trust boundary being the host-only network — `VRRP_ROUTER_ID` is the knob to
coexist with another keepalived lab.

While no cluster exists the check fails on every CP: they all lose 30 points, the relative order
holds, and the VIP is carried anyway — which is what `kubeadm init` needs. kube-vip remains a
good option *once the cluster runs* (`--services` mode); it is the bootstrap role that fails here.

The VIP is used **even with a single control plane**, for the same reason: pointing
`controlPlaneEndpoint` at cp1's real IP would turn "1 CP → 3 CPs" into regenerating every
certificate and redistributing every kubeconfig, instead of a plain `join`.

### 8.2 containerd 2.x from the Docker repo

Debian 13 ships containerd **1.7.24**. Only the 2.x branch implements the CRI `RuntimeConfig`
method kubeadm uses to read the runtime's cgroup driver. On 1.36 its absence is a preflight
**warning**; the fallback disappears in **1.37**, and the backport to 1.7 was **refused**
([containerd#11346](https://github.com/containerd/containerd/issues/11346), closed without
merge). `CONTAINERD_SOURCE=debian` stays available for an offline lab, and is a dead end for
upgrades.

`SystemdCgroup = true` matters more than the kubelet's `cgroupDriver` field: Debian 13 is
cgroup v2 with systemd as the manager, and leaving containerd on `cgroupfs` puts two managers on
one hierarchy — nodes then get unstable under load.

> ⚠️ **The 1.7 → 2.x trap**: the `pause` image key changed *name and location*. Config v2 has
> `sandbox_image` under `[plugins."io.containerd.grpc.v1.cri"]`; config v3 has `sandbox` under
> `[plugins.'io.containerd.cri.v1.images'.pinned_images]`. A config copied over as-is silently
> loses the setting, so `provision.sh` regenerates it from `containerd config default` on every
> run and patches whichever key is present. The tag itself comes from
> `kubeadm config images list`, never hard-coded: a mismatch is invisible online and fatal offline.

### 8.3 kubeadm API `v1beta4`

Default since Kubernetes 1.31; `v1beta3` is deprecated. The breaking change to know: `extraArgs`
and `kubeletExtraArgs` are no longer **maps** but **lists of `{name, value}`**, so a flag can be
repeated. Any file written before 1.31 is invalid as-is, and kubeadm's error does not point at
the shape.

```yaml
# v1beta3:  extraArgs: {bind-address: "0.0.0.0"}
# v1beta4:  extraArgs: [{name: bind-address, value: "0.0.0.0"}]
```

`make validate-kubeadm` catches exactly this, in CI, without a cluster.

### 8.4 What kubeadm does not do, and `cluster-up.sh` does

- **Worker role labels** — kubeadm sets none, so `kubectl get nodes` shows `<none>` and
  `node-role.kubernetes.io/worker` selectors match nothing.
- **The control-plane taint**: `UNTAINT_CP=auto` removes it only when `WORKERS=0`, which is what
  makes a 1-VM lab usable.
- **Control-plane metrics**: `bind-address: 0.0.0.0` on `controllerManager` and `scheduler`, which
  otherwise listen on loopback and give Prometheus two DOWN targets with no explanation.
- **Pre-pulled images**, during `vagrant up` and in parallel across VMs, so `kubeadm init`
  downloads nothing — the biggest source of bootstrap timeouts. Workers pull only `pause` and
  `kube-proxy`, saving ~500 MiB each.
- **Swap** off and masked, systemd swap units included (`/etc/fstab` does not describe those).

The `/vagrant` synced folder is a **mechanism**, not a convenience: `cluster-up.sh` renders configs
on the host and the VMs read them at `/vagrant/_out/`, so nothing needs `scp` and no secret is
passed on a command line where it would land in shell history. `_out/join.env` does hold the
bootstrap token and the certificate key, readable from every VM — fine for a lab, not a pattern for
production.

---

## 🌐 9. CNI: Cilium, Calico or Flannel

**kubeadm installs no CNI, ever.** Unlike the Talos twin — where flannel can be laid down by the
OS at bootstrap — the pod network here is *always* installed afterwards by
`./_k8s/platform-up.sh`. `CNI` is read by `cluster-up.sh` (for the kube-proxy decision and
`_out/cluster.env`) and by the platform step (which chart to install).

| `CNI=` | `LoadBalancer` IP | `_k8s/` layer usable |
|---|---|---|
| **`cilium`** *(default)* | ✅ pool + L2/ARP announcement | ✅ yes |
| `calico` | ❌ BGP only | ⚠️ needs MetalLB on top |
| `flannel` | ❌ | ❌ no |
| `none` | ❌ | depends on what you install |

**In practice: keep `cilium`.** It is the only value that gives Services an `EXTERNAL-IP` on a
host-only network, and therefore the only one that gets you the HTTPS UIs. `calico` is there to
compare CNIs and work on `NetworkPolicy`
([its page](https://github.com/OPS-NC/k8s-playground/blob/main/calico/README.md)); `flannel` for
a deliberately bare cluster.

> ⚠️ **`KUBE_PROXY_REPLACEMENT=true` requires `CNI=cilium`**, and `cluster-up.sh` refuses any
> other combination. With `--skip-phases=addon/kube-proxy` and no replacement, **no ClusterIP
> answers at all** — not even CoreDNS reaching the API. The error message offers the two ways
> out: `CNI=cilium`, or `KUBE_PROXY_REPLACEMENT=false`.

> ℹ️ Cilium needs `k8sServiceHost`/`k8sServicePort` when kube-proxy is gone: nothing provisions
> the apiserver's ClusterIP, so the agent cannot bootstrap through `kubernetes.default`. The lab
> points it at the **VIP**, which also means the agents survive the loss of any single CP.

> ⚠️ **`POD_CIDR` must be the CIDR the CNI really announces.** Cilium in `cluster-pool` mode
> defaults to `10.0.0.0/8`, unrelated to what kubeadm was told; `cilium-up.sh` passes `POD_CIDR`
> back to it explicitly. Two divergent values give a broken pod network that looks configured.

> ⚠️ **Switching CNI on a live cluster is not supported.** `./kubeadm/cluster-reset.sh` (or
> `vagrant destroy`) first: two CNIs fight over the pod network, and the leftover datapath is
> exactly what `node-reset.sh` exists to clean.

---

## 🛠️ 10. Validating a change

Everything validates **without booting a cluster**:

```bash
make validate       # shell + YAML + Vagrantfile + kubeadm templates + doc links
make docs           # regenerates docs/index.html from every README (EN + FR)
make help           # lists the targets
```

| Target | What it covers |
|---|---|
| `validate-shell` | `bash -n` on every `*.sh` tracked by git |
| `validate-yaml` | parses every git-tracked `*.yaml` / `*.yml` (PyYAML, fetched by `uv`) |
| `validate-vagrant` | `vagrant validate`; locally it also checks the provider config |
| `validate-defaults` | asserts the fallback defaults in the `Vagrantfile` and in `cluster-up.sh` still match `lab.env.example`, key by key |
| `validate-kubeadm` | renders the 3 templates with dummy values in a throwaway dir, parses them, then runs `kubeadm config validate` **if `kubeadm` is in your PATH** |
| `validate-docs` | builds the docs into a throwaway file and fails on any dead `*.md` link or unknown anchor |

`validate-kubeadm` earns its keep: it catches a real v1beta4 schema error instead of letting you
discover it ten minutes into a `vagrant up`. On CI, where `kubeadm` is installed, the schema
check always runs.

The `ci` workflow calls these same `make` targets on every pull request, so a check cannot pass
in CI and fail on your machine. It also asserts the guard rails actually fire —
`CONTROL_PLANES=2 vagrant validate` **must** be rejected. Nothing in the `Makefile` touches a
running cluster or regenerates secrets: `make validate` is safe on a lab that is up.

> ℹ️ `validate-shell` and `validate-yaml` only cover files tracked by **this** repo. The `_k8s/`
> submodule is one pointer, so none of its scripts are checked here — they are validated in
> k8s-playground's own CI.

---

## 📄 11. License

**Apache License 2.0** — see
[`LICENSE`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/LICENSE). Use it, modify it,
redistribute it, including commercially, as long as you keep the copyright notice and state your
changes. **No warranty**: this is a lab, do not run it in production.

It covers what this repo contains — the `Vagrantfile`, the `kubeadm/` scripts, the templates, the
manifests, the docs. It does not extend to the third-party components those scripts download
(Kubernetes, containerd, keepalived, Cilium, Envoy Gateway, Longhorn, Vault…), nor to the `_k8s/`
submodule: [k8s-playground](https://github.com/OPS-NC/k8s-playground) carries its own `LICENSE`.
