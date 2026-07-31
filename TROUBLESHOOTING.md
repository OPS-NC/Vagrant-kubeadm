<!-- i18n -->
**English** · [Français](DEPANNAGE.md)
<!-- /i18n -->

# 🚑 Troubleshooting

> Organised by **observed symptom**, because that is what you actually have: an error
> message, not a theory. Install path: [`README.md`](README.md) · application layer:
> [`_k8s/README.md`](_k8s/README.md) · version bumps:
> [`kubeadm/UPGRADE.md`](kubeadm/UPGRADE.md).

Each `_k8s/<addon>/README.md` carries its **own** pitfalls section for what is specific to it
(Longhorn, Vault, Calico…). This page covers the lab itself: the host, VirtualBox, keepalived,
kubeadm and the Debian nodes.

Unless stated otherwise, every command runs **from the repository root**, with:

```bash
export KUBECONFIG="$PWD/kubeconfig"
```

---

## 🖥️ 1. Host and VirtualBox

### `vagrant up` dies on `VERR_VMX_IN_VMX_ROOT_MODE`

```
VBoxManage: error: VT-x is being used by another hypervisor (VERR_VMX_IN_VMX_ROOT_MODE).
VBoxManage: error: VirtualBox can't operate in VMX root mode.
```

**Cause.** VirtualBox and KVM cannot hold **VT-x** at the same time. If the KVM kernel module
is loaded — and on most Linux distributions it is loaded at boot — VirtualBox cannot start a
single VM.

```bash
# 1. Is KVM loaded? (Intel: kvm_intel — AMD: kvm_amd)
lsmod | grep kvm

# 2. Unload it (fails if a KVM/libvirt VM is still running — stop it first)
sudo modprobe -r kvm_intel kvm      # AMD: sudo modprobe -r kvm_amd kvm
```

> 💡 KVM comes back on every boot. If this host is **never** used for KVM/libvirt, blacklist it
> once:
> ```bash
> echo -e "blacklist kvm_intel\nblacklist kvm" | sudo tee /etc/modprobe.d/disable-kvm.conf
> ```
> To revert: delete that file and reboot.

### VirtualBox refuses the `192.168.56.0/24` host-only network

VirtualBox 7 only allows host-only addresses that are explicitly permitted. Allow the range:

```
# /etc/vbox/networks.conf
* 192.168.56.0/21
```

The whole lab lives in that `/24` (nodes, the `192.168.56.5` VIP, the `.200`–`.230`
LoadBalancer pool), so nothing works until VirtualBox accepts it.

### `vagrant up` refuses to start on an even number of control planes

```
Vagrant-KubeADM : CONTROL_PLANES=2 est PAIR — etcd exige un nombre impair pour tenir
un quorum utile (1, 3, 5). Avec 2 membres, la perte d'un seul node fige l'API.
```

**This is a guard rail, not a bug.** etcd holds quorum at `(n/2)+1`: two members tolerate
**zero** failures while costing twice as much as one. Use `CONTROL_PLANES=1`, `3` or `5` in
`lab.env`. `kubeadm/cluster-up.sh` refuses the same value, on purpose — the two checks are
deliberately redundant.

The `Vagrantfile` also refuses a node IP that collides with `192.168.56.1` (host-only gateway),
`.2` (VirtualBox DHCP), `.100` (VirtualBox's default host-only DHCP range) or the VIP, and it
refuses two nodes on the same IP. Those errors all name the offending variable
(`CP_IP_START`/`CP_IP_STEP`, `WK_IP_START`/`WK_IP_STEP`).

---

## 🌐 2. The API VIP and keepalived

### `cluster-up.sh` fails on "l'apiserver ne répond pas sur la VIP"

```
    - attente de https://192.168.56.5:6443 ......................... ÉCHEC (600s)
ERREUR : l'apiserver ne répond pas sur la VIP 192.168.56.5 après 600s.
```

`kubeadm init` has already run at that point: the script is waiting for `/readyz` **through the
VIP**, which is the address every other node will use to join. The script itself lists the two
causes, by frequency.

**Cause 1 — keepalived is not carrying the VIP.**

```bash
vagrant ssh k8s-cp1 -c "ip -4 addr show | grep 192.168.56.5"
vagrant ssh k8s-cp1 -c "sudo systemctl status keepalived"
vagrant ssh k8s-cp1 -c "sudo journalctl -u keepalived -n 50 --no-pager"
```

What to look for:

| Observation | Meaning |
|---|---|
| `ip -4 addr show` prints nothing for `.5` | no node holds the VIP |
| `keepalived.service: failed`, `Cant find interface` in the journal | keepalived was configured on the wrong interface |
| `Entering BACKUP STATE` on every control plane | the peers see each other but nobody promotes |

The interface is **detected**, never hard-coded: `kubeadm/provision.sh` looks for the interface
that carries the node's IP and writes it to `/etc/kubeadm-lab/node.env`. Check what it found:

```bash
vagrant ssh k8s-cp1 -c "cat /etc/kubeadm-lab/node.env"
vagrant ssh k8s-cp1 -c "sudo sed -n '/vrrp_instance/,\$p' /etc/keepalived/keepalived.conf"
```

If `HOSTONLY_IF` fell back to `eth1` while the VM really uses `enp0s8`, keepalived binds to an
interface that does not exist. Re-run `vagrant provision k8s-cp1` once the VM has its host-only
address.

**Cause 2 — the apiserver itself does not start.**

```bash
vagrant ssh k8s-cp1 -c "sudo crictl ps -a | grep apiserver"
vagrant ssh k8s-cp1 -c "sudo journalctl -u kubelet -n 50 --no-pager"
vagrant ssh k8s-cp1 -c "sudo crictl logs \$(sudo crictl ps -a -q --name kube-apiserver | head -1)"
```

A `CrashLoopBackOff` apiserver is almost always etcd underneath it: check `crictl ps -a | grep
etcd` and section 5 below. Note that keepalived's health check
(`/usr/local/bin/check-apiserver.sh`, hitting `https://127.0.0.1:6443/livez` every 3 s) only
subtracts 30 points from the priority — it never removes the VIP entirely, so the VIP being up
proves nothing about the apiserver.

### The VIP is held by TWO nodes at once (VRRP split-brain)

**Symptom.** `kubectl` behaves erratically — one request succeeds, the next times out — and:

```bash
for n in k8s-cp1 k8s-cp2 k8s-cp3; do
  echo -n "$n: " ; vagrant ssh "$n" -c "ip -4 -o addr show | grep -c 192.168.56.5" -- -q
done
# healthy: exactly one node answers 1, the others 0
```

The journal shows `Entering MASTER STATE` on **two** nodes.

**Cause.** VRRP here is **unicast** (`unicast_src_ip` + `unicast_peer`), not multicast, because
multicast is the first thing to misbehave on a VirtualBox host-only switch. If a control plane
does not see its peers, it believes it is alone and promotes itself.

```bash
# The peer list must contain every OTHER control plane IP
vagrant ssh k8s-cp1 -c "sudo sed -n '/unicast/,/}/p' /etc/keepalived/keepalived.conf"

# The router ID must be IDENTICAL on all control planes
for n in k8s-cp1 k8s-cp2 k8s-cp3; do
  vagrant ssh "$n" -c "sudo sed -n 's/.*virtual_router_id //p' /etc/keepalived/keepalived.conf" -- -q
done

vagrant ssh k8s-cp2 -c "sudo journalctl -u keepalived -n 80 --no-pager"
```

Three real causes, in order of likelihood:

1. **A missing `unicast_peer` block** — the node fell back to multicast. This used to happen
   when a control plane was provisioned while `CONTROL_PLANES` was still `1`: with no peer to
   list, keepalived does **not** reject the config, it silently reverts to multicast. Growing
   the lab afterwards then left `cp1` in multicast while `cp2`/`cp3` spoke unicast — and the two
   modes are *mutually deaf*, so both sides believed they were alone and both took the VIP.
   `provision.sh` now always lists the **five** control-plane IPs the addressing plan allows,
   so a config written for one CP is already correct for three. A node still missing the block
   was provisioned by an older revision of the repo: `vagrant provision <node>` rewrites it.
2. **Divergent `VRRP_ROUTER_ID`** — the nodes were provisioned with different `lab.env` values.
   All control planes of one cluster must share the same ID.
3. **Another keepalived lab on the same host-only network using the same ID** (default `51`).
   Two groups with the same `virtual_router_id` fight over the VIP. Change `VRRP_ROUTER_ID` in
   `lab.env`, then `vagrant provision`.

> ℹ️ There is **no** VRRP password on purpose: VRRPv2 authentication sends it in clear text and
> buys nothing. The trust boundary is the host-only network; the isolation knob is
> `VRRP_ROUTER_ID`.

---

## ☸️ 3. Nodes and kubeadm

### The nodes stay `NotReady`

```
NAME      STATUS     ROLES           AGE   VERSION
k8s-cp1   NotReady   control-plane   2m    v1.36.3
k8s-w1    NotReady   worker          1m    v1.36.3
```

**This is NORMAL between `kubeadm/cluster-up.sh` and `_k8s/platform-up.sh`.** kubeadm installs
no CNI, and a node with no pod network never reports `Ready`. `cluster-up.sh` says so itself in
its closing banner.

Confirm the diagnosis rather than guessing:

```bash
kubectl describe node k8s-cp1 | sed -n '/Conditions:/,/Addresses:/p'
```

The `Ready` condition reads `False`, with reason `KubeletNotReady` and a message containing:

```
container runtime network not ready: NetworkReady=false reason:NetworkPluginNotReady
message:Network plugin returns error: cni plugin not initialized
```

**Fix:** run the next step.

```bash
./_k8s/platform-up.sh
```

With `CNI=none` nothing will ever install a network — that is the meaning of the setting, and
`cluster-up.sh` prints a different closing message in that case.

If the nodes are **still** `NotReady` after the CNI install:

```bash
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system logs ds/cilium --tail=50
kubectl -n kube-system logs deploy/cilium-operator --tail=50
```

### CoreDNS stays `Pending`

```
kube-system   coredns-xxxxxxxxx-aaaaa   0/1   Pending   0   3m
kube-system   coredns-xxxxxxxxx-bbbbb   0/1   Pending   0   3m
```

**Same cause: there is no CNI yet.** Every node carries the `node.kubernetes.io/not-ready`
taint, which CoreDNS does not tolerate, so the scheduler has nowhere to put it.

```bash
kubectl -n kube-system describe pod -l k8s-app=kube-dns | sed -n '/Events:/,$p'
# FailedScheduling … node(s) had untolerated taint {node.kubernetes.io/not-ready: }
```

CoreDNS schedules itself as soon as the first node turns `Ready`. Nothing to fix: run
`./_k8s/platform-up.sh`. If CoreDNS is still `Pending` **after** the nodes are `Ready`, then
look at real scheduling constraints (`WORKERS=0` with `UNTAINT_CP=false`, for instance, leaves
nowhere to schedule).

### Every node shows the same IP, `10.0.2.15`

```bash
kubectl get nodes -o wide
# NAME      INTERNAL-IP   …
# k8s-cp1   10.0.2.15     …
# k8s-w1    10.0.2.15     …
# k8s-w2    10.0.2.15     …
```

**Cause.** Each VM has two NICs: **NIC1 = VirtualBox NAT** (always `10.0.2.15`, *identical on
every VM*) and **NIC2 = host-only** (the real cluster address). Without
`kubeletExtraArgs: node-ip`, the kubelet picks the default-route interface — the NAT one — and
every node registers with the same address. `kubectl get nodes` looks plausible, but logs,
`kubectl exec`, probes and cross-node traffic all go to the wrong place.

This lab sets `node-ip` in all three kubeadm templates, so you only hit this if a node was
joined **by hand** with the printed `kubeadm join` line — that line cannot carry `node-ip`, and
`kubeadm join` has no equivalent flag. That is precisely why the lab joins nodes through
`JoinConfiguration` files.

```bash
# What the kubelet was actually given
vagrant ssh k8s-w1 -c "cat /var/lib/kubelet/kubeadm-flags.env"
# expected: KUBELET_KUBEADM_ARGS="… --node-ip=192.168.56.101 …"
```

**Fix.** The supported path is to redo the join through the repo:

```bash
./kubeadm/cluster-reset.sh && ./kubeadm/cluster-up.sh
```

To repair a single node without touching the rest: edit
`/var/lib/kubelet/kubeadm-flags.env` to add `--node-ip=<host-only IP>`, then
`sudo systemctl restart kubelet`. If `INTERNAL-IP` does not change, delete the `Node` object
(`kubectl delete node k8s-w1`) so the kubelet re-registers from scratch.

### `kubeadm join` fails on an expired token or an invalid certificate key

Three distinct messages, three lifetimes:

| Message (excerpt) | What expired | Lifetime |
|---|---|---|
| `couldn't validate the identity of the API Server: could not find a JWS signature in the cluster-info ConfigMap for token ID` | the bootstrap token | **24 h** |
| `error downloading certs: … Secret "kubeadm-certs" was not found in the "kube-system" Namespace` | the certificate key (the Secret is garbage-collected with it) | **2 h** |
| `error decoding certificate key` / decryption failure | the certificate key does not match the Secret | **2 h** |

**Cause.** `kubeadm init` prints a token valid for 24 hours and a certificate key valid for
**two hours only**. Any join attempt after that window fails with an opaque error.

**Fix — the easy one.** Re-run the bootstrap script: it is idempotent, and
`kubeadm/node-init.sh` **regenerates both elements on every run** before rewriting
`_out/join.env`. Joining a node hours or days after the initial `init` is therefore a supported
path.

```bash
./kubeadm/cluster-up.sh
```

**Fix — by hand,** if you are driving kubeadm yourself:

```bash
vagrant ssh k8s-cp1 -c "sudo kubeadm init phase upload-certs --upload-certs"   # new certificate key
vagrant ssh k8s-cp1 -c "sudo kubeadm token create --print-join-command"        # new token + CA hash
```

Both commands are safe to replay on a running cluster.

### kubeadm preflight complains about swap, CPU count or memory

```
[ERROR Swap]: swap is enabled; production deployments should disable swap …
[ERROR NumCPU]: the number of available CPUs 1 is less than the required 2
[ERROR Mem]: the system RAM (1024 MB) is less than the minimum 1700 MB
```

**Swap.** `kubeadm/provision.sh` already handles it: `swapoff -a`, commenting out the swap line
in `/etc/fstab`, **and** masking any systemd swap unit (Debian 13 can provide swap through a
unit that `/etc/fstab` never mentions — that is how swap comes back after a reboot). If the
error shows up anyway, provisioning did not run or did not finish:

```bash
vagrant ssh k8s-cp1 -c "free -m ; swapon --show ; systemctl list-unit-files --type=swap"
vagrant provision k8s-cp1
```

> ℹ️ NodeSwap is GA since 1.34, but `failSwapOn` still defaults to `true`: the kubelet refuses
> to start with swap on until you configure it explicitly. On a lab, disabling swap is the
> shortest and best-tested path.

**CPU and memory.** The thresholds are kubeadm's own: **2 vCPU** and **~1700 MiB** on a control
plane. The repo defaults (`CP_MEM=3072`, `CP_CPU=2`, `WK_MEM=2048`, `WK_CPU=2`) clear them —
this only bites after lowering them in `lab.env`. `2048` boots but leaves a stacked etcd about
350 MiB of headroom; `_k8s/observability/` wants `4096`.

```bash
# after editing lab.env, resources only change on a VM restart
vagrant reload k8s-cp1
```

### A preflight warning about `RuntimeConfig` or the cgroup driver

A **warning** (not an error) telling you kubeadm could not read the cgroup driver from the
container runtime and is falling back to the `cgroupDriver` field of `KubeletConfiguration`.

**Cause.** Only containerd **2.x** implements the CRI `RuntimeConfig` method that kubeadm uses
to ask the runtime which cgroup driver it uses. Debian 13 ships containerd **1.7.24**, which
never will: the backport was refused upstream (containerd#11346, closed without merge).

```bash
vagrant ssh k8s-cp1 -c "containerd --version"
vagrant ssh k8s-cp1 -c "sudo grep SystemdCgroup /etc/containerd/config.toml"   # must be true
```

- With `CONTAINERD_SOURCE=docker` (the default) you get containerd 2.x from the Docker
  repository and the warning disappears.
- With `CONTAINERD_SOURCE=debian` you get containerd 1.7 and the warning is expected. It is
  harmless **in 1.36**, because the `cgroupDriver` fallback still exists and the lab sets it to
  `systemd`. That fallback is **removed in 1.37** — the same setup then fails instead of
  warning, and the `cgroupDriver` field itself goes away in 1.38. `CONTAINERD_SOURCE=debian` is
  for an offline lab, and it is a dead end for upgrades.

> ⚠️ What really matters is `SystemdCgroup = true` in `/etc/containerd/config.toml`. Debian 13
> is cgroup v2 with systemd as the manager; leaving containerd on `cgroupfs` makes two managers
> fight over the same hierarchy and the nodes go unstable under load.

---

## 🔌 4. Pod network and Services

### After a `cluster-reset.sh`, the pod network behaves inexplicably

**Symptoms.** Pods get IPs but cross-node traffic dies; DNS fails while `ping 1.1.1.1` works;
the Cilium agent complains about pre-existing BPF maps or a datapath it did not create.

**Cause.** `kubeadm reset` deliberately leaves behind what it did not lay down: CNI interfaces,
**pinned eBPF programs**, and kube-proxy's iptables rules. A later `kubeadm init` then inherits
a ghost datapath.

`kubeadm/node-reset.sh` is the cleanup, and `cluster-reset.sh` runs it on every node. It:

- removes `/etc/cni/net.d/*`;
- deletes `cilium_host`, `cilium_net`, `cilium_vxlan`, `flannel.1`, `cni0`, `vxlan.calico`,
  `kube-ipvs0`, plus every `lxc*` and `cali*` interface;
- removes the pinned eBPF programs under `/sys/fs/bpf/tc/globals/cilium_*`;
- flushes the `KUBE-`/`CILIUM_`/`cali-` iptables chains and clears IPVS;
- wipes `/var/lib/etcd`, `/var/lib/cni`, `/run/flannel` and restarts containerd.

Check by hand what is left on a suspect node:

```bash
vagrant ssh k8s-w1 -c "ip -o link show | grep -E 'cilium|lxc|flannel|cali|cni0'"
vagrant ssh k8s-w1 -c "sudo ls /sys/fs/bpf/tc/globals/ 2>/dev/null"
vagrant ssh k8s-w1 -c "sudo iptables-save | grep -cE 'KUBE-|CILIUM_|cali-'"
vagrant ssh k8s-w1 -c "ls -la /etc/cni/net.d/"
```

Anything non-empty on a supposedly reset node means the cleanup did not complete — the script
prints `reset partiel sur <node> — poursuite` and carries on rather than stopping. Re-run it on
that node alone:

```bash
vagrant ssh k8s-w1 -c "sudo bash /vagrant/kubeadm/node-reset.sh"
```

If in doubt, `vagrant destroy -f && vagrant up` is the guaranteed clean slate — a fresh VM has
no residue by construction.

> ℹ️ `cluster-reset.sh` is also the correct tool when you want to change `POD_CIDR`,
> `SERVICE_CIDR`, the CNI or the VIP: all four are frozen at `kubeadm init` time and cannot be
> changed on a live cluster.

### A `LoadBalancer` Service stays `<pending>`

```bash
kubectl -n envoy-gateway-system get svc
# TYPE           EXTERNAL-IP   …
# LoadBalancer   <pending>     …
```

**Cause 1 — the CNI is not Cilium.** In this lab only Cilium hands out Service IPs (L2/ARP
announcement). Calico can only do it over BGP, and there is no peer router on a host-only
network (MetalLB required); flannel and `none` do nothing at all. `_k8s/platform-up.sh` says so
explicitly when it runs, and it strips the Cilium-specific
`loadBalancerClass: io.cilium/l2-announcer` so another announcer could take over.

```bash
sed -n 's/^CNI=//p' _out/cluster.env      # what the cluster was actually built with
```

> ⚠️ `_out/cluster.env` is the truth (written at bootstrap); `lab.env` is only an *intent* and
> may have been edited afterwards.

**Cause 2 — the L2 pool is missing, exhausted or announced on the wrong interface.**

```bash
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
kubectl -n kube-system logs deploy/cilium-operator --tail=50
sed -n 's/^HOSTONLY_IF=//p' _out/cluster.env
```

The pool is `192.168.56.200`–`.230` by default (`LB_POOL_START`/`LB_POOL_END`), and the
announcement interface comes from the **detected** `HOSTONLY_IF`, not a hard-coded name. A pool
that overlaps the node range, or an announcement policy pinned to an interface that does not
exist, both produce a permanent `<pending>`.

Changing the pool is a re-run away:

```bash
./_k8s/cilium/cilium-up.sh
```

---

## 🗄️ 5. etcd and cluster performance

### etcd loses its leader, or the whole cluster crawls

**Symptoms.**

```
etcdserver: request timed out
apply request took too long
waiting for ReadIndex response took too long, retrying
leader changed
```

`kubectl` takes seconds to answer, pods stay `Pending`, the apiserver restarts on its own.

```bash
kubectl get --raw='/healthz/etcd'
kubectl -n kube-system logs -l component=etcd --tail=50
vagrant ssh k8s-cp1 -c "sudo crictl logs \$(sudo crictl ps -q --name etcd | head -1) 2>&1 | tail -40"
vagrant ssh k8s-cp1 -c "free -m ; uptime"
```

**Causes, in order of frequency on this lab:**

1. **fsync latency.** etcd commits every write to disk before acknowledging it. On VirtualBox,
   a VM disk on a spinning drive — or on an SSD already saturated by the host — pushes fsync
   past etcd's tolerance and the leader election starts flapping. **Keep the VM disks on an
   SSD**, and do not run a 3-control-plane topology next to a heavy build.
2. **`CP_MEM` too low.** A stacked etcd on a 2048 MiB control plane has roughly 350 MiB of
   headroom; the first `_k8s/` addons eat it. `3072` is the real floor,
   `_k8s/observability/` wants `4096`.
3. **Clock drift.** etcd is very sensitive to it. The `Vagrantfile` already lowers the guest
   additions' time-sync threshold to 1000 ms, which covers a suspend/resume cycle — but a VM
   left suspended for a long time is better off reloaded:
   ```bash
   vagrant reload k8s-cp1
   ```

> ⚠️ With 3 control planes, etcd tolerates **one** failure. Do not stop two of them at the same
> time (including during an upgrade — see [`kubeadm/UPGRADE.md`](kubeadm/UPGRADE.md)): the API
> freezes until quorum is back.

---

## 🔐 6. Lab UIs over HTTPS

### An HTTPS UI is unreachable

Work down the chain, in this order — each step assumes the previous one.

**1. Does the Gateway have an IP?**

```bash
kubectl -n envoy-gateway-system get gateway main-gateway -o jsonpath='{.status.addresses[0].value}'; echo
```

Empty or `<pending>` → this is a LoadBalancer problem, see section 4. The expected address is
the **first IP of the pool**, `192.168.56.200` by default.

**2. Does the name resolve to that IP?**

The lab domain (`LAB_DOMAIN`, `kubeadm.lab.example.io` by default) has no reason to resolve on
your machine. `_k8s/platform-up.sh` prints the line to add:

```bash
# /etc/hosts on the HOST
192.168.56.200  argo.kubeadm.lab.example.io grafana.kubeadm.lab.example.io vault.kubeadm.lab.example.io
```

…or a wildcard `A` record `*.<LAB_DOMAIN> → 192.168.56.200` if you own a DNS zone. Check:

```bash
getent hosts argo.kubeadm.lab.example.io
ping -c1 192.168.56.200
```

> ⚠️ On the ACME path (`SELF_SIGNED=false`) behind Cloudflare, the record must be **DNS-only
> (grey cloud)**: the Cloudflare proxy cannot reach a private IP.

**3. Is there an `HTTPRoute` for that hostname?**

```bash
kubectl get httproute -A
kubectl -n <ns> describe httproute <name> | sed -n '/Status:/,$p'   # Accepted / ResolvedRefs
```

**4. Is the TLS mode the one you think it is?**

```bash
sed -n 's/^SELF_SIGNED=//p' lab.env
kubectl -n envoy-gateway-system get secret | grep wildcard
```

| Mode | Expected behaviour |
|---|---|
| `SELF_SIGNED=true` (default) | a **local CA** signs the wildcard; the browser warns until you import `_out/self-signed/ca.crt`. No cert-manager is installed. |
| `SELF_SIGNED=false`, `LAB_ACME_ISSUER=staging` | Let's Encrypt **staging**: the certificate is real but **not trusted** — a browser warning is expected. |
| `SELF_SIGNED=false`, `LAB_ACME_ISSUER=prod` | publicly trusted — but limited to **5 certificates per week** for a given `*.<LAB_DOMAIN>`. |

A browser warning is therefore *normal* in two of the three modes. To trust the local CA:

```bash
sudo cp _out/self-signed/ca.crt /usr/local/share/ca-certificates/vagrant-kubeadm-lab.crt
sudo update-ca-certificates
```

**5. Still nothing?** Look at the proxy itself:

```bash
kubectl -n envoy-gateway-system get pods
kubectl -n envoy-gateway-system logs deploy/envoy-gateway --tail=50
```

---

## 🧰 7. Toolbox

### From the host

```bash
vagrant status                       # which VMs exist and are running
vagrant ssh k8s-cp1                  # interactive shell
vagrant ssh k8s-cp1 -c "<command>" -- -q -o LogLevel=ERROR   # one shot, quiet (what the scripts use)
vagrant provision k8s-cp1            # replay provision.sh (idempotent)
vagrant reload k8s-cp1               # restart, applying new CPU/RAM from lab.env

export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl get --raw='/readyz?verbose'

cat _out/cluster.env                 # what the cluster was REALLY built with
```

> ⚠️ `_out/join.env` holds the **join token and the certificate key**. `_out/` is gitignored,
> but it is readable by every VM through the `/vagrant` synced folder. Never paste its contents
> anywhere.

### Inside a VM

```bash
cat /etc/kubeadm-lab/node.env                 # role, node IP, detected host-only interface
ip -4 addr show                               # is the VIP here?
sudo systemctl status kubelet containerd keepalived

sudo journalctl -u kubelet -f                 # follow live
sudo journalctl -u kubelet -n 100 --no-pager
sudo journalctl -u containerd -n 50 --no-pager
sudo journalctl -u keepalived -n 50 --no-pager

sudo crictl ps -a                             # containers, including dead ones
sudo crictl pods                              # sandboxes
sudo crictl logs <container-id>
sudo crictl images

sudo kubeadm certs check-expiration           # control planes only
sudo kubeadm config images list --kubernetes-version v1.36.3
```

> 💡 `crictl` talks to the same socket as the kubelet thanks to `/etc/crictl.yaml`, written by
> `provision.sh`. Without it, `crictl` goes looking for dockershim and prints confusing errors.

### The nuclear options, from least to most destructive

| Command | What it destroys | When |
|---|---|---|
| `vagrant provision <node>` | nothing | re-apply system prerequisites |
| `./kubeadm/cluster-up.sh` | nothing (idempotent) | replay a partial bootstrap, add nodes |
| `./kubeadm/cluster-reset.sh` | etcd, certificates, every workload — **keeps the VMs** | change `POD_CIDR`, `SERVICE_CIDR`, the CNI or the VIP |
| `vagrant destroy -f && vagrant up` | everything | any doubt about system-level residue |

---

## 📚 References

- [kubeadm — Troubleshooting](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/troubleshooting-kubeadm/)
- [kubeadm — Configuring a cgroup driver](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/configure-cgroup-driver/)
- [Kubernetes — Debugging DNS resolution](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)
- [Cilium — Troubleshooting](https://docs.cilium.io/en/stable/operations/troubleshooting/)
- [etcd — Tuning](https://etcd.io/docs/latest/tuning/)
- [`kubeadm/UPGRADE.md`](kubeadm/UPGRADE.md) — version bumps and certificate renewal
