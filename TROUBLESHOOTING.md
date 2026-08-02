<!-- i18n -->
**English** · [Français](DEPANNAGE.md)
<!-- /i18n -->

# 🚑 Troubleshooting

> Organised by **observed symptom**, because that is what you have: an error message, not a
> theory. Install path: [`README.md`](README.md) · application layer:
> <https://ops-nc.github.io/k8s-playground/> · version bumps:
> [`kubeadm/UPGRADE.md`](kubeadm/UPGRADE.md).

This page covers the lab itself: the host, VirtualBox, keepalived, kubeadm and the Debian nodes.
Addon problems (Longhorn, Vault, Calico…) are documented with the addons, in
[k8s-playground](https://ops-nc.github.io/k8s-playground/).

Unless stated otherwise, commands run **from the repository root**, with
`export KUBECONFIG="$PWD/kubeconfig"`.

---

## 🖥️ 1. Host, repository and VirtualBox

### `vagrant up` dies on `VERR_VMX_IN_VMX_ROOT_MODE`

```
VBoxManage: error: VT-x is being used by another hypervisor (VERR_VMX_IN_VMX_ROOT_MODE).
```

VirtualBox and KVM cannot hold **VT-x** at the same time, and most Linux distributions load KVM
at boot.

```bash
lsmod | grep kvm                    # Intel: kvm_intel — AMD: kvm_amd
sudo modprobe -r kvm_intel kvm      # fails if a KVM/libvirt VM is still running
```

> 💡 KVM comes back on every boot. If this host never runs KVM/libvirt, blacklist it once:
> ```bash
> echo -e "blacklist kvm_intel\nblacklist kvm" | sudo tee /etc/modprobe.d/disable-kvm.conf
> ```

### VirtualBox refuses the `192.168.56.0/24` host-only network

VirtualBox 7 only allows explicitly permitted host-only ranges:

```
# /etc/vbox/networks.conf
* 192.168.56.0/21
```

The whole lab lives in that `/24` — nodes, the `.5` VIP, the `.200`–`.230` LoadBalancer pool — so
nothing works until VirtualBox accepts it.

### `vagrant up` refuses an even number of control planes

```
Vagrant-KubeADM: CONTROL_PLANES=2 is EVEN — etcd requires an odd number to hold a
useful quorum (1, 3, 5). With 2 members, losing a single node freezes the API.
```

A guard rail, not a bug: etcd holds quorum at `(n/2)+1`, so two members tolerate **zero**
failures while costing twice as much as one. Use `1`, `3` or `5`. The `Vagrantfile` also refuses a
node IP colliding with `.1`, `.2`, `.100` or the VIP, and refuses duplicates; each error names the
offending variable.

### `_k8s/` is empty — `./_k8s/platform-up.sh: No such file or directory`

`_k8s/` is a **git submodule**. A plain `git clone` records it but does not check it out.

```bash
git submodule update --init --recursive     # fills _k8s/
git -C _k8s log --oneline -1                # sanity check
```

Clone correctly next time with `git clone --recurse-submodules <url>`. `git pull` does not update
the submodule either — repeat the command above after every pull, or
`git submodule update --remote _k8s` to jump to the latest upstream commit.

### The `_k8s/` scripts find neither `lab.env` nor the kubeconfig

Symptoms: addons install into the **wrong domain** (`lab.example.io` instead of your
`LAB_DOMAIN`), the **wrong CNI** is chosen, or `kubectl` inside the scripts fails with
`connection refused`. The banner the scripts print at start-up shows `lab.env: absent (defaults)`.

The lab was not located. k8s-playground has no `Vagrantfile` of its own: it takes the directory
*containing* `_k8s/` as the lab, provided that directory carries a `Vagrantfile` — that is where
`lab.env`, `_out/` and `kubeconfig` live. The same walk decides the distribution
(`kubeadm/cluster-up.sh` next to the `Vagrantfile` = kubeadm lab), so a lab that is not found also
means a distribution that is not detected.

```bash
ls Vagrantfile lab.env kubeadm/cluster-up.sh   # marker, config, distro signature
ls -d _k8s/lib                                 # _k8s/ really is INSIDE the lab
```

Typical causes: `_k8s/` cloned on its own somewhere else, a `lab.env` never created from
`lab.env.example`, or scripts invoked through a symlink landing outside the lab. The pointer
always wins over detection:

```bash
LAB_DIR=/path/to/Vagrant-kubeadm ./_k8s/platform-up.sh
```

> 💡 `LAB_ENV=/path/to/lab.env` does the same when the file is elsewhere or named differently.
> `LAB_DIR` is the one to remember: it drives `lab.env`, `_out/cluster.env` **and** the default
> `KUBECONFIG` at once.

---

## 🌐 2. The API VIP and keepalived

### `cluster-up.sh` fails on "the apiserver does not answer on the VIP"

```
    - waiting for https://192.168.56.5:6443 ....................... FAILED (600s)
ERROR: the apiserver does not answer on the VIP 192.168.56.5 after 600s.
```

`kubeadm init` has already run: the script is waiting for `/readyz` **through the VIP**, the
address every other node will use to join. Two causes, by frequency.

**Cause 1 — keepalived is not carrying the VIP.**

```bash
vagrant ssh k8s-cp1 -c "ip -4 addr show | grep 192.168.56.5"
vagrant ssh k8s-cp1 -c "sudo systemctl status keepalived"
vagrant ssh k8s-cp1 -c "sudo journalctl -u keepalived -n 50 --no-pager"
```

| Observation | Meaning |
|---|---|
| nothing printed for `.5` | no node holds the VIP |
| `keepalived.service: failed`, `Cant find interface` | keepalived was configured on the wrong interface |
| `Entering BACKUP STATE` on every control plane | the peers see each other but nobody promotes |

The interface is **detected**, never hard-coded — check what `provision.sh` found:

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

A `CrashLoopBackOff` apiserver is almost always etcd underneath — see section 5. Note that
keepalived's health check only subtracts 30 priority points, it never drops the VIP, so **the VIP
being up proves nothing about the apiserver.**

### The VIP is held by TWO nodes at once (VRRP split-brain)

`kubectl` behaves erratically — one request succeeds, the next times out — and the journal shows
`Entering MASTER STATE` on two nodes.

```bash
for n in k8s-cp1 k8s-cp2 k8s-cp3; do
  echo -n "$n: " ; vagrant ssh "$n" -c "ip -4 -o addr show | grep -c 192.168.56.5" -- -q
done
# healthy: exactly one node answers 1, the others 0
```

VRRP here is **unicast** (`unicast_src_ip` + `unicast_peer`), not multicast, because multicast is
the first thing to misbehave on a VirtualBox host-only switch. A control plane that does not see
its peers believes it is alone and promotes itself.

```bash
# the peer list must contain every OTHER control plane IP
vagrant ssh k8s-cp1 -c "sudo sed -n '/unicast/,/}/p' /etc/keepalived/keepalived.conf"

# the router ID must be IDENTICAL on all control planes
for n in k8s-cp1 k8s-cp2 k8s-cp3; do
  vagrant ssh "$n" -c "sudo sed -n 's/.*virtual_router_id //p' /etc/keepalived/keepalived.conf" -- -q
done
```

Three causes, in order of likelihood:

1. **A missing `unicast_peer` block** — keepalived does not reject such a config, it silently
   reverts to multicast, and the two modes are *mutually deaf*. `vagrant provision <node>`
   rewrites it (the config always lists the five control-plane IPs the addressing plan allows, so
   a config written for one CP is already correct for three).
2. **Divergent `VRRP_ROUTER_ID`** — nodes provisioned with different `lab.env` values. All
   control planes of one cluster must share the same ID.
3. **Another keepalived lab on the same host-only network with the same ID** (default `51`).
   Change `VRRP_ROUTER_ID`, then `vagrant provision`.

> ℹ️ There is no VRRP password on purpose: VRRPv2 authentication sends it in clear text and buys
> nothing. The trust boundary is the host-only network; the isolation knob is `VRRP_ROUTER_ID`.

---

## ☸️ 3. Nodes and kubeadm

### The nodes stay `NotReady`, CoreDNS stays `Pending`

```
NAME      STATUS     ROLES           AGE   VERSION
k8s-cp1   NotReady   control-plane   2m    v1.36.3
k8s-w1    NotReady   worker          1m    v1.36.3
```

**Normal between `cluster-up.sh` and the platform step.** kubeadm installs no CNI, and a node
with no pod network never reports `Ready`. CoreDNS follows: every node carries the
`node.kubernetes.io/not-ready` taint, which it does not tolerate.

```bash
kubectl describe node k8s-cp1 | sed -n '/Conditions:/,/Addresses:/p'
# Ready False — KubeletNotReady — cni plugin not initialized
```

Fix: `./_k8s/platform-up.sh`. With `CNI=none` nothing will ever install a network — that is what
the setting means, and `cluster-up.sh` prints a different closing message in that case.

Still `NotReady` after the CNI install, or CoreDNS still `Pending` after the nodes are `Ready`:

```bash
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system logs ds/cilium --tail=50
kubectl -n kube-system logs deploy/cilium-operator --tail=50
```

`WORKERS=0` with `UNTAINT_CP=false` also leaves nowhere to schedule.

### Every node shows the same IP, `10.0.2.15`

```
# NAME      INTERNAL-IP
# k8s-cp1   10.0.2.15
# k8s-w1    10.0.2.15
```

Each VM has two NICs: NIC1 = VirtualBox NAT (always `10.0.2.15`, *identical on every VM*) and
NIC2 = host-only (the real cluster address). Without `kubeletExtraArgs: node-ip` the kubelet picks
the default-route interface — the NAT one. `kubectl get nodes` looks plausible, but logs, `exec`,
probes and cross-node traffic all go to the wrong place.

The lab sets `node-ip` in all three templates, so you only hit this on a node joined **by hand**
with the printed `kubeadm join` line — that line cannot carry `node-ip`.

```bash
vagrant ssh k8s-w1 -c "cat /var/lib/kubelet/kubeadm-flags.env"
# expected: KUBELET_KUBEADM_ARGS="… --node-ip=192.168.56.101 …"
```

Supported fix: redo the join through the repo (`./kubeadm/cluster-reset.sh && ./kubeadm/cluster-up.sh`).
To repair a single node, add `--node-ip=<host-only IP>` to
`/var/lib/kubelet/kubeadm-flags.env` and `systemctl restart kubelet`; if `INTERNAL-IP` does not
change, `kubectl delete node k8s-w1` so the kubelet re-registers.

### `kubeadm join` fails on an expired token or certificate key

| Message (excerpt) | What expired | Lifetime |
|---|---|---|
| `could not find a JWS signature in the cluster-info ConfigMap for token ID` | the bootstrap token | **24 h** |
| `error downloading certs: … Secret "kubeadm-certs" was not found` | the certificate key (the Secret is garbage-collected with it) | **2 h** |
| `error decoding certificate key` / decryption failure | the key does not match the Secret | **2 h** |

Easy fix: re-run `./kubeadm/cluster-up.sh`. It is idempotent, and `node-init.sh` regenerates both
elements on every run before rewriting `_out/join.env` — joining a node days after the initial
`init` is a supported path.

By hand, if you are driving kubeadm yourself (both are safe to replay on a running cluster):

```bash
vagrant ssh k8s-cp1 -c "sudo kubeadm init phase upload-certs --upload-certs \\
     --config /vagrant/_out/kubeadm-init.yaml"                                  # new certificate key
vagrant ssh k8s-cp1 -c "sudo kubeadm token create --print-join-command"        # new token + CA hash
```

> ⚠️ Run `upload-certs` **with `--config`**. Without it, kubeadm builds its API client from a
> `LocalAPIEndpoint.AdvertiseAddress` it detects off the default route — `10.0.2.15` in any
> Vagrant VM — and TLS fails on `x509: certificate is valid for …, not 10.0.2.15`. The endpoint is
> what must be corrected: never add `10.0.2.15` to `certSANs`, it identifies no node at all.

### kubeadm preflight complains about swap, CPU count or memory

```
[ERROR Swap]: swap is enabled; production deployments should disable swap …
[ERROR NumCPU]: the number of available CPUs 1 is less than the required 2
[ERROR Mem]: the system RAM (1024 MB) is less than the minimum 1700 MB
```

**Swap** is already handled by `provision.sh`: `swapoff -a`, the `/etc/fstab` line commented out,
**and** any systemd swap unit masked (Debian 13 can provide swap through a unit `/etc/fstab` never
mentions — that is how swap comes back after a reboot). The error showing up anyway means
provisioning did not finish:

```bash
vagrant ssh k8s-cp1 -c "free -m ; swapon --show ; systemctl list-unit-files --type=swap"
vagrant provision k8s-cp1
```

**CPU and memory** thresholds are kubeadm's own: 2 vCPU and ~1700 MiB on a control plane. The repo
defaults clear them, so this only bites after lowering them in `lab.env`. Resources change on a VM
restart: `vagrant reload k8s-cp1`.

> ℹ️ NodeSwap is GA since 1.34, but `failSwapOn` still defaults to `true`: the kubelet refuses to
> start with swap on until you configure it explicitly. On a lab, disabling swap is the shortest
> and best-tested path.

### A preflight warning about `RuntimeConfig` or the cgroup driver

A **warning**, not an error: kubeadm could not read the cgroup driver from the container runtime
and fell back to the `cgroupDriver` field of `KubeletConfiguration`. Only containerd **2.x**
implements the CRI `RuntimeConfig` method it uses; Debian 13 ships **1.7.24**, which never will
(backport refused upstream, containerd#11346).

```bash
vagrant ssh k8s-cp1 -c "containerd --version"
vagrant ssh k8s-cp1 -c "sudo grep SystemdCgroup /etc/containerd/config.toml"   # must be true
```

With `CONTAINERD_SOURCE=docker` (the default) the warning disappears. With
`CONTAINERD_SOURCE=debian` it is expected — harmless in 1.36, **fatal in 1.37** where the fallback
is removed, so that value is an offline-lab option and a dead end for upgrades.

> ⚠️ What really matters is `SystemdCgroup = true`. Debian 13 is cgroup v2 with systemd as the
> manager; leaving containerd on `cgroupfs` makes two managers fight over one hierarchy and the
> nodes go unstable under load.

---

## 🔌 4. Pod network and Services

### After a `cluster-reset.sh`, the pod network behaves inexplicably

Pods get IPs but cross-node traffic dies; DNS fails while `ping 1.1.1.1` works; the Cilium agent
complains about pre-existing BPF maps.

`kubeadm reset` deliberately leaves behind what it did not lay down: CNI interfaces, **pinned eBPF
programs**, and kube-proxy's iptables rules, so a later `kubeadm init` inherits a ghost datapath.
`kubeadm/node-reset.sh` is the cleanup and `cluster-reset.sh` runs it everywhere — it removes
`/etc/cni/net.d/*`, the `cilium_*`/`flannel.1`/`cni0`/`vxlan.calico`/`kube-ipvs0`/`lxc*`/`cali*`
interfaces, the pinned programs under `/sys/fs/bpf/tc/globals/cilium_*`, the `KUBE-`/`CILIUM_`/
`cali-` chains and IPVS, then wipes `/var/lib/etcd`, `/var/lib/cni`, `/run/flannel` and restarts
containerd.

Check what is left on a suspect node:

```bash
vagrant ssh k8s-w1 -c "ip -o link show | grep -E 'cilium|lxc|flannel|cali|cni0'"
vagrant ssh k8s-w1 -c "sudo ls /sys/fs/bpf/tc/globals/ 2>/dev/null"
vagrant ssh k8s-w1 -c "sudo iptables-save | grep -cE 'KUBE-|CILIUM_|cali-'"
```

Anything non-empty means the cleanup did not complete — the script prints `partial reset on
<node> — carrying on` rather than stopping. Re-run it there:
`vagrant ssh k8s-w1 -c "sudo bash /vagrant/kubeadm/node-reset.sh"`. In doubt,
`vagrant destroy -f && vagrant up` is the guaranteed clean slate.

> ℹ️ `cluster-reset.sh` is also the right tool to change `POD_CIDR`, `SERVICE_CIDR`, the CNI or
> the VIP: all four are frozen at `kubeadm init` time.

### A `LoadBalancer` Service stays `<pending>`

**Cause 1 — the CNI is not Cilium.** Only Cilium hands out Service IPs here (L2/ARP announcement).
Calico needs BGP and there is no peer router on a host-only network (MetalLB required); flannel
and `none` do nothing.

```bash
sed -n 's/^CNI=//p' _out/cluster.env      # what the cluster was actually built with
```

> ⚠️ `_out/cluster.env` is the truth (written at bootstrap); `lab.env` is only an *intent* and may
> have been edited afterwards.

**Cause 2 — the L2 pool is missing, exhausted or announced on the wrong interface.**

```bash
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
kubectl -n kube-system logs deploy/cilium-operator --tail=50
sed -n 's/^HOSTONLY_IF=//p' _out/cluster.env
```

The pool is `192.168.56.200`–`.230` by default, and the announcement interface comes from the
**detected** `HOSTONLY_IF`. A pool overlapping the node range, or a policy pinned to an interface
that does not exist, both give a permanent `<pending>`. Changing the pool is a re-run away:
`./_k8s/cilium/cilium-up.sh`.

---

## 🗄️ 5. etcd and cluster performance

### etcd loses its leader, or the whole cluster crawls

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
vagrant ssh k8s-cp1 -c "free -m ; uptime"
```

Causes, in order of frequency on this lab:

1. **fsync latency.** etcd commits every write to disk before acknowledging it. On VirtualBox, a
   VM disk on a spinning drive — or on an SSD already saturated by the host — pushes fsync past
   etcd's tolerance and leader election starts flapping. Keep the VM disks on an SSD, and do not
   run a 3-control-plane topology next to a heavy build.
2. **`CP_MEM` too low.** A stacked etcd on 2048 MiB has ~350 MiB of headroom; the first addons eat
   it. `3072` is the real floor, `_k8s/observability/` wants `4096`.
3. **Clock drift.** etcd is very sensitive to it. The `Vagrantfile` lowers the guest additions'
   time-sync threshold to 1000 ms, which covers a suspend/resume cycle — but a VM left suspended
   for a long time is better off `vagrant reload`-ed.

> ⚠️ With 3 control planes etcd tolerates **one** failure. Do not stop two at the same time
> (during an upgrade included — see [`kubeadm/UPGRADE.md`](kubeadm/UPGRADE.md)): the API freezes
> until quorum is back.

---

## 🔐 6. Lab UIs over HTTPS

Work down the chain, in order — each step assumes the previous one.

**1. Does the Gateway have an IP?**

```bash
kubectl -n envoy-gateway-system get gateway main-gateway -o jsonpath='{.status.addresses[0].value}'; echo
```

Empty or `<pending>` → a LoadBalancer problem, see section 4. The expected address is the first IP
of the pool, `192.168.56.200` by default.

**2. Does the name resolve to that IP?**

`LAB_DOMAIN` has no reason to resolve on your machine. `platform-up.sh` prints the line to add:

```bash
# /etc/hosts on the HOST
192.168.56.200  argo.kubeadm.lab.example.io grafana.kubeadm.lab.example.io
```

…or a wildcard `A` record `*.<LAB_DOMAIN>` → `192.168.56.200` if you own a DNS zone (**DNS-only**
behind Cloudflare: the proxy cannot reach a private IP).

```bash
getent hosts argo.kubeadm.lab.example.io
```

> ⚠️ **Do not test the Gateway IP with `ping`.** A Service IP announced in L2 by Cilium answers
> **ARP** and **TCP** but not ICMP — no interface actually carries the address. A failing `ping`
> on `.200` is normal and proves nothing, while `ping` on a *node* works, which makes the false
> negative convincing. The real proof that the announcement works is the ARP entry resolving to a
> node's MAC:
> ```bash
> sudo ip neigh flush 192.168.56.200
> curl -s -o /dev/null --max-time 5 http://192.168.56.200/    # 404 = Envoy answers
> ip neigh show 192.168.56.200                                # lladdr = the announcing node
> ```

**3. Is there an `HTTPRoute` for that hostname?**

```bash
kubectl get httproute -A
kubectl -n <ns> describe httproute <name> | sed -n '/Status:/,$p'   # Accepted / ResolvedRefs
```

> ℹ️ On the **bare IP**, `http://` answers `404` (Envoy is listening, no route matches) but
> `https://` answers nothing at all: the TLS listener is scoped by hostname, so a request without
> SNI matches no listener. Test with the name, short-circuiting DNS if needed:
> `curl -sk --resolve argo.kubeadm.lab.example.io:443:192.168.56.200 https://argo.kubeadm.lab.example.io/`.

**4. Is the TLS mode the one you think it is?**

```bash
sed -n 's/^SELF_SIGNED=//p' lab.env
kubectl -n envoy-gateway-system get secret | grep wildcard
```

| Mode | Expected behaviour |
|---|---|
| `SELF_SIGNED=true` (default) | a **local CA** signs the wildcard; the browser warns until you import `_out/self-signed/ca.crt`. No cert-manager installed. |
| `SELF_SIGNED=false`, `LAB_ACME_ISSUER=staging` | Let's Encrypt **staging**: real certificate, **not trusted** — a browser warning is expected. |
| `SELF_SIGNED=false`, `LAB_ACME_ISSUER=prod` | publicly trusted — limited to **5 certificates per week** for a given `*.<LAB_DOMAIN>`. |

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

> ⚠️ `_out/join.env` holds the **join token and the certificate key**. `_out/` is gitignored, but
> readable by every VM through the `/vagrant` synced folder. Never paste its contents anywhere.

### Inside a VM

```bash
cat /etc/kubeadm-lab/node.env                 # role, node IP, detected host-only interface
ip -4 addr show                               # is the VIP here?
sudo systemctl status kubelet containerd keepalived

sudo journalctl -u kubelet -f
sudo journalctl -u containerd -n 50 --no-pager
sudo journalctl -u keepalived -n 50 --no-pager

sudo crictl ps -a                             # containers, including dead ones
sudo crictl logs <container-id>

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
- [Cilium — Troubleshooting](https://docs.cilium.io/en/stable/operations/troubleshooting/)
- [etcd — Tuning](https://etcd.io/docs/latest/tuning/)
- [`kubeadm/UPGRADE.md`](kubeadm/UPGRADE.md) — version bumps and certificate renewal
- [k8s-playground](https://ops-nc.github.io/k8s-playground/) — the `_k8s/` application layer,
  addon by addon, with its own pitfalls sections
