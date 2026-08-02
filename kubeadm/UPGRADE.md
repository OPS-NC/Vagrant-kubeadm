<!-- i18n -->
**English** · [Français](MISE-A-JOUR.md)
<!-- /i18n -->

# ⬆️ Upgrading Kubernetes

> Moving this lab from one Kubernetes version to the next **with kubeadm**, the way you would on a
> real cluster. Install path: [`../README.md`](../README.md) · symptoms:
> [`../TROUBLESHOOTING.md`](../TROUBLESHOOTING.md).

Reference at the time of writing: Kubernetes **1.36.3**, apt repository **`v1.36`**, containerd
**2.2.6**, Cilium **1.20.0**, `CNI=cilium`. Adapt node names and IPs to your topology
(`lab.env`); the repo default is 1 control plane + 2 workers.

> ⚠️ Unlike the Talos sibling lab, this procedure has **not** been timed on a live run. It is the
> upstream kubeadm procedure transposed to this repo's variables and scripts; every command is
> quoted from the documentation linked in §6.

---

## 🎯 1. The two rules you cannot bend

**One MINOR version at a time.** `1.36 → 1.37 → 1.38`, never `1.36 → 1.38`. This is not a kubeadm
quirk: the API deprecation policy requires `kube-apiserver` not to skip minors, even on a
single-instance cluster, and `kubeadm upgrade apply` refuses a target more than one minor above
the current version. Patch versions inside a minor are free (`1.36.3 → 1.36.7`).

**The kubelet must never be ahead of the apiserver.**

| Component | Allowed relative to `kube-apiserver` |
|---|---|
| `kube-apiserver` (HA, several control planes) | within **1 minor** of each other |
| `kubelet` | up to **3 minors older** — **never newer** |
| `kubectl` | 1 minor either side |

That dictates the order of the whole procedure: **control plane first, kubelet last**. Upgrading a
node's `kubelet` package before `kubeadm upgrade apply` has run puts a 1.37 kubelet in front of a
1.36 apiserver.

> ⚠️ **Never run `vagrant provision` to "upgrade" the lab.** `provision.sh` unholds the packages
> and installs `kubelet`/`kubeadm`/`kubectl` at `K8S_VERSION` with
> `--allow-change-held-packages`, **on every node at once**, without ever calling
> `kubeadm upgrade`. Bumping `lab.env` and re-provisioning would jump every kubelet to the new
> minor while the control plane is still on the old one. `vagrant provision` is for a **fresh** VM.

---

## 📦 2. Held packages, and one apt repository per MINOR

`provision.sh` ends its package step with `apt-mark hold kubelet kubeadm kubectl`. An upgrade must
be a deliberate act, never the side effect of an `apt upgrade` inside a VM — which would silently
break the kubelet/apiserver skew. So every upgrade starts with `apt-mark unhold` and ends with
`apt-mark hold`. Check with `vagrant ssh k8s-cp1 -c "apt-mark showhold"`.

**There is one apt repository per Kubernetes minor**, and this is the step people miss:

```
https://pkgs.k8s.io/core:/stable:/v1.36/deb/
```

The `v1.36` repository will **never** offer 1.37. Staying on it makes
`apt-get install kubeadm=1.37.x-*` answer *"Version '1.37.x-*' for 'kubeadm' was not found"* — and
people conclude the release does not exist.

Here the repository file is generated from **`K8S_APT_MINOR`** and the package version from
**`K8S_VERSION`**. Both live in `lab.env` and **must move together**:

```bash
# lab.env
K8S_VERSION=1.37.0
K8S_APT_MINOR=v1.37
```

> ⚠️ Both also have **fallback defaults duplicated** in the `Vagrantfile` and in
> `kubeadm/cluster-up.sh` (`K8S_VERSION` only there), so that a lab without a `lab.env` still
> works. Bump them in the same commit as `lab.env.example`, or a lab built without `lab.env`
> restarts on the old version.

---

## 🧭 3. The lab shortcut: destroy and rebuild

On a disposable lab, the fastest and safest path is not the upgrade at all:

```bash
# lab.env: K8S_VERSION=1.37.0 and K8S_APT_MINOR=v1.37
vagrant destroy -f
vagrant up
./kubeadm/cluster-up.sh
./_k8s/platform-up.sh
```

Clean cluster on the target version, no half-upgraded state, in roughly the time a careful rolling
upgrade takes on three nodes. Use §4 instead when you want to **practise the upgrade** — that is
the reason to run a kubeadm lab in the first place, and here a mistake costs a `vagrant destroy`.

---

## ⚡ 4. The real procedure, on a running cluster

Everything runs **inside the VMs** (`vagrant ssh <node>`), except the `kubectl` commands, which
run from the host with `KUBECONFIG=$PWD/kubeconfig`. `1.37.x` stands for the exact target patch
version; the `-*` suffix in the `apt-get install` lines is intentional, since the Debian revision
is not always `-1.1`.

### 4.1 Pre-flight — never start from a degraded cluster

```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide                 # every node Ready, all on the same version
kubectl get pods -A | grep -v Running     # nothing broken before you start
kubectl get --raw='/healthz/etcd'
vagrant ssh k8s-cp1 -c "sudo kubeadm certs check-expiration"
```

Read the target release's [changelog](https://git.k8s.io/kubernetes/CHANGELOG), then check two
lab-specific constraints:

| Constraint | Why it matters here |
|---|---|
| **containerd 2.x** | the CRI `RuntimeConfig` fallback disappears in **1.37**, turning a lab built with `CONTAINERD_SOURCE=debian` (containerd 1.7) from a 1.36 *warning* into a 1.37 *failure*. Check `containerd --version` first. |
| **Cilium ↔ Kubernetes** | Cilium supports a bounded set of Kubernetes versions; check its release notes and plan §5 accordingly. |

> 💡 `kubeadm upgrade` pulls new control plane images. With `REGISTRY_MIRROR` set they come from
> the mirror; otherwise the node needs Internet access through its NAT NIC.

### 4.2 Every node starts with the same two steps

On **each** node, in the order of §4.3 → §4.5:

```bash
# 1. Point apt at the NEW minor's repository
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

# 2. Upgrade kubeadm ONLY
sudo apt-mark unhold kubeadm && \
sudo apt-get update && sudo apt-get install -y kubeadm='1.37.x-*' && \
sudo apt-mark hold kubeadm
kubeadm version
```

And every node **ends** with the same four:

```bash
kubectl drain <node> --ignore-daemonsets
sudo apt-mark unhold kubelet kubectl && \
sudo apt-get update && sudo apt-get install -y kubelet='1.37.x-*' kubectl='1.37.x-*' && \
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon <node>
```

> 💡 If the drain stalls on a pod with an `emptyDir`, add `--delete-emptydir-data`. If it stalls on
> a PodDisruptionBudget (Longhorn is the usual suspect), fix the PDB rather than forcing;
> `--disable-eviction` is the blunt instrument of last resort.

What changes between node roles is only the middle step.

### 4.3 First control plane (`k8s-cp1`) — `upgrade apply`

Between the two blocks of §4.2:

```bash
sudo kubeadm upgrade plan          # what would happen
sudo kubeadm upgrade apply v1.37.x # the step that upgrades the control plane
```

`upgrade apply` rewrites the static pod manifests for `kube-apiserver`,
`kube-controller-manager`, `kube-scheduler` and `etcd`, and **renews the certificates it manages on
this node** (§5).

> ⚠️ With `CONTROL_PLANES=1` the API is **unavailable** while the static pods roll. Expected on a
> single control plane, and the best argument for practising this on a 3-CP topology.

```bash
kubectl get nodes                  # k8s-cp1 Ready, VERSION v1.37.x
kubectl get --raw='/healthz/etcd'
```

### 4.4 The other control planes (`k8s-cp2`, `k8s-cp3`) — `upgrade node`

**One node at a time**, checking etcd between each: with 3 control planes the quorum is 2, and
losing two at once freezes the API. The middle step becomes:

```bash
sudo kubeadm upgrade node
```

> ⚠️ The `192.168.56.5` VIP moves on its own while a control plane restarts — keepalived's health
> check (`/livez/ping` every 3 s, `weight -30`) drops the restarting node behind a healthy peer.
> Watch the failover happen:
> ```bash
> while true; do curl -sk -o /dev/null -w '%{http_code} ' https://192.168.56.5:6443/livez; sleep 1; done
> ```

### 4.5 The workers (`k8s-w1`, `k8s-w2`, …)

Same `kubeadm upgrade node` (on a worker it only updates the local kubelet config), one node at a
time. Workers hold no etcd member, so nothing here can break quorum — but draining them all at
once takes every workload down.

### 4.6 After the upgrade

```bash
kubectl get nodes -o wide            # every node Ready, all on v1.37.x
kubectl get pods -A | grep -v Running
kubectl version
```

Then write the new version back into the repo, so a future rebuild starts where you left off:

| File | What to change |
|---|---|
| `lab.env` | `K8S_VERSION=1.37.x` **and** `K8S_APT_MINOR=v1.37` |
| `lab.env.example` | the same two lines (the versioned template) |
| `Vagrantfile` | the `K8S_VERSION` / `K8S_APT_MINOR` fallback defaults |
| `kubeadm/cluster-up.sh` | the `K8S_VERSION` fallback default |

Three of those four carry a **duplicated** default on purpose — a safety net when `lab.env` is
missing. Two defaults that diverge give an incoherent lab: packages from one minor, generated
configuration for another. `make validate-defaults` checks that pair, key by key.

---

## 🔐 5. Certificates, containerd and Cilium

### Certificates

kubeadm issues client and serving certificates valid for **1 year**, signed by a CA valid for
**10 years**.

```bash
vagrant ssh k8s-cp1 -c "sudo kubeadm certs check-expiration"
```

**An upgrade renews them for you**: `kubeadm upgrade` (both `apply` and `node`) renews the
certificates it manages on that node, unless `--certificate-renewal=false`. A cluster upgraded at
least once a year never sees an expired certificate — which is why the yearly expiry rarely bites
in production and always bites on a lab VM left suspended for months.

Manual renewal, when no upgrade is due:

```bash
vagrant ssh k8s-cp1
sudo kubeadm certs renew all
sudo systemctl restart kubelet    # reloads the control plane static pods
```

> ⚠️ Renewing also renews `admin.conf`, which the host's `kubeconfig` was copied from. Refresh it,
> or `kubectl` keeps presenting the old client certificate:
> ```bash
> vagrant ssh k8s-cp1 -c "sudo cp /etc/kubernetes/admin.conf /vagrant/_out/admin.conf"
> cp -f _out/admin.conf kubeconfig && chmod 0600 kubeconfig
> ```

Two things kubeadm does **not** renew: the CA itself (10 years, beyond any lab's life) and the
kubelet's own client certificate, which rotates automatically under `/var/lib/kubelet/pki`. None of
this concerns the two short-lived items used for **joining** a node — the bootstrap token (24 h)
and the certificate key (2 h), both regenerated on every `cluster-up.sh` run.

### containerd

Kubernetes, the container runtime and the CNI are **three independent release trains**. Bump one at
a time and check the cluster in between.

`containerd.io` is **not** held by `provision.sh`, so it moves with a plain `apt upgrade` inside a
VM — usually harmless, but it restarts every container on that node:

```bash
kubectl drain k8s-w1 --ignore-daemonsets
vagrant ssh k8s-w1 -c "sudo apt-get update && sudo apt-get install -y --only-upgrade containerd.io"
kubectl uncordon k8s-w1
```

`provision.sh` regenerates `/etc/containerd/config.toml` from `containerd config default` on every
run and patches whichever `pause` key the format uses, so the 1.7 → 2.x rename cannot silently
lose the setting — do not hand-edit that file and expect it to survive. Going back to
`CONTAINERD_SOURCE=debian` is a **downgrade to a dead end**: containerd 1.7 will never implement
`RuntimeConfig` and cannot carry you past 1.36.

### Cilium

```bash
# lab.env: CILIUM_VERSION=1.2x.y
./_k8s/cilium/cilium-up.sh
```

Run it from the repository root; the [k8s-playground](https://github.com/OPS-NC/k8s-playground)
submodule finds the lab and the distribution on its own. The script is a
`helm upgrade --install`, so it is the same command whether you install or upgrade. Read the Cilium
upgrade notes first: a minor bump can require a one-off pre-flight step, and this lab depends on
two Cilium features that must keep working — `kubeProxyReplacement` (there is **no kube-proxy** to
fall back to) and the L2 announcement that gives the Envoy Gateway its IP.

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n envoy-gateway-system get svc      # the Gateway must keep its EXTERNAL-IP
```

Everything else in the VMs (keepalived included) follows a plain `apt upgrade`, which is safe
precisely because `kubelet`/`kubeadm`/`kubectl` are held.

---

## 📚 References

- [kubeadm — Upgrading kubeadm clusters](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/)
- [Kubernetes — Version skew policy](https://kubernetes.io/releases/version-skew-policy/)
- [kubeadm — Certificate management](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/)
- [Kubernetes — Installing kubeadm (apt repositories)](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [Cilium — Upgrade guide](https://docs.cilium.io/en/stable/operations/upgrade/)
- [`../TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) — symptoms and fixes
