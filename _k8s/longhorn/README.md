<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🐮 `longhorn/` — replicated block storage (Longhorn 1.12) on kubeadm/Debian

> Provides `PersistentVolume`s **replicated across workers** (StorageClass `longhorn`) carved out
> of the node disks, with no hardware and no cloud provider. It is the lab's only **HA** storage:
> a volume survives the loss of a node, unlike `../local-path-storage/`.

## 🎯 Purpose

Ship two StorageClasses and the CSI driver behind them:

| StorageClass | Block replicas | Default | For whom |
|---|---|---|---|
| `longhorn` | one per worker, capped at 3 | yes (`values.yaml`) | data worth protecting: `../wordpress-example/`, `../vault-cluster/` |
| `longhorn-r1` | 1 | no | `../cloudnative-pg/` and `../observability/` (application-level replication, or rebuildable data) |

Files in this directory:

| File | Purpose |
|---|---|
| `longhorn-up.sh` | **the install**: namespace, chart + both StorageClasses + `HTTPRoute` |
| `values.yaml` | Helm values: `defaultDataPath`, `defaultReplicaCount`, `persistence.defaultClass: true` |
| `longhorn-r1-storageclass.yaml` | Baseline StorageClass `longhorn-r1` (1 block replica) |
| `httproute.yaml` | HTTPS `HTTPRoute` `longhorn.kubeadm.lab.example.io` → `longhorn-frontend:80` on `main-gateway` |

## 📋 Prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| **iSCSI on every node** (`open-iscsi` + `nfs-common`, `iscsid` running, `iscsi_tcp` module) — **already installed by `kubeadm/provision.sh`** | `longhorn-manager` and the CSI plugin shell out to `iscsiadm` to attach volumes. Without it, the CSI pods `CrashLoopBackOff` with `iscsiadm: not found` | `vagrant ssh k8s-w1 -c 'systemctl is-active iscsid && lsmod \| grep iscsi_tcp'` |
| `helm` in `PATH` | the chart | `helm version` |
| Namespace `longhorn-system` with PodSecurity `privileged` | Longhorn pods are privileged (iSCSI, hostPath) — **applied by `longhorn-up.sh`** | `kubectl get ns longhorn-system --show-labels` |
| `../envoy-gateway/` + `../cert-manager/` (optional) | only to expose the UI over HTTPS | `kubectl get gateway -n envoy-gateway-system` |

> ℹ️ **Coming from the Talos lab? The two hard prerequisites are gone.** They were the reason
> this addon used to be the most convoluted one in the repo:
>
> | Talos | Debian |
> |---|---|
> | `iscsi-tools` + `util-linux-tools` **system extensions**, *baked* into the installer image. A node without them could not be fixed live — it had to be re-installed or upgraded to a new Image Factory ref. `longhorn-up.sh` could only *check* (`talosctl get extensions`) and refuse to go further. | Two **apt packages**. `kubeadm/provision.sh` runs `apt-get install -y open-iscsi nfs-common`, `systemctl enable --now iscsid` and loads `iscsi_tcp` (`/etc/modules-load.d/iscsi.conf`) on **every** node, at provisioning time. Nothing to check, nothing to bake. |
> | An `rshared` **kubelet mount** on `/var/lib/longhorn`, applied with `talosctl patch mc`: the Talos kubelet runs in a container and lacks bidirectional mount propagation. | `/var/lib/longhorn` is a plain directory on the root filesystem, and the kubelet runs directly on the host: mount propagation is already correct. Nothing to patch. |
>
> Consequence: no more `talosctl`, no more `TALOSCONFIG`, and the files `patch-longhorn.yaml`
> and `schematic.yaml` **no longer exist** in this repo. The install script went from 5 steps
> to 3.

## ⚡ Install

Pinned version: chart **Longhorn 1.12.0**.

```bash
./_k8s/longhorn/longhorn-up.sh
```

Idempotent: re-runnable without breaking anything (`helm upgrade --install`). It covers **both**
steps below. It **counts the schedulable worker nodes on the live cluster** (rather than trusting
`WORKERS` in `lab.env`, which only states an intent) and aligns the block replica count with it,
capped at 3. `REPLICAS=…` forces the count, `LONGHORN_VERSION=…` overrides the chart version.

> ℹ️ With `WORKERS=0` the control planes are untainted (`UNTAINT_CP=auto`) and become the only
> storage nodes: the script counts them instead of bailing out.

### 1. Namespace + Pod Security — *automated by `longhorn-up.sh`*

```bash
kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite
```

> ℹ️ A kubeadm cluster enforces **no** PodSecurity level by default, so these labels change
> nothing today. They are kept because they **document the intent** and keep the namespace
> working if the cluster is hardened later (`--admission-control-config-file` on the apiserver).

### 2. Helm chart + baseline StorageClass — *automated by `longhorn-up.sh`*

```bash
helm repo add longhorn https://charts.longhorn.io && helm repo update
# --version: pin it; check the latest on charts.longhorn.io
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version 1.12.0 \
  -f _k8s/longhorn/values.yaml
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer
kubectl apply -f _k8s/longhorn/longhorn-r1-storageclass.yaml
```

## 🔧 Under the hood

### Why `longhorn-r1` (1 replica)

The `Vagrantfile` attaches **no extra disk**: Longhorn shares the box's single virtual disk with
the OS, the container images and etcd. Stacking 3-replica volumes on it triggers
`ReplicaSchedulingFailure` (and `DiskPressure` evictions before that). `longhorn-r1` cuts
consumption by ~3 for the cases where block replication is pointless: rebuildable data
(Prometheus, Loki) or data already replicated by the application (CloudNativePG, 3 instances).
Defined **once** here, consumed elsewhere.

> ℹ️ For a **critical** database, stay on `longhorn` (3 replicas) or explicitly delegate
> resilience to the application.

### Dedicated disk (the "clean" setup, optional)

Longhorn 1.10+ recommends a dedicated disk. Here, by default, we stay on `/var/lib/longhorn`
(the box's single disk). To do it properly:

1. **VirtualBox**: attach one extra `.vdi` per worker (SATA controller, next port) — this needs
   an addition to the `Vagrantfile` (a `vb.customize ["createhd", …]` / `["storageattach", …]`
   block).
2. **Debian**: partition, format and mount it persistently, then point `defaultDataPath` at it:
   ```bash
   sudo mkfs.ext4 -L longhorn /dev/sdb
   echo 'LABEL=longhorn /mnt/longhorn ext4 defaults 0 2' | sudo tee -a /etc/fstab
   sudo mkdir -p /mnt/longhorn && sudo mount -a
   ```
   ```bash
   helm upgrade longhorn longhorn/longhorn -n longhorn-system \
     --reuse-values --set defaultSettings.defaultDataPath=/mnt/longhorn
   ```
   No mount-propagation patch is needed — that was a Talos constraint.

## ✅ Verify

```bash
vagrant ssh k8s-w1 -c 'systemctl is-active iscsid'   # active
vagrant ssh k8s-w1 -c 'lsmod | grep iscsi_tcp'       # module loaded
kubectl -n longhorn-system get pods              # instance-manager, manager, csi-* Running
kubectl get storageclass                         # longhorn (default) + longhorn-r1
kubectl -n longhorn-system get nodes.longhorn.io # every node "Schedulable", disk Ready

# Quick test: a PVC must bind
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: test-longhorn }
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn
  resources: { requests: { storage: 1Gi } }
EOF
kubectl get pvc test-longhorn                    # Bound
kubectl delete pvc test-longhorn
```

> ℹ️ Longhorn ships an **environment check script** that audits every node (iSCSI, NFS,
> `multipathd`, kernel modules) — the fastest way to confirm the Debian prerequisites:
> `curl -sSfL https://raw.githubusercontent.com/longhorn/longhorn/v1.12.0/scripts/environment_check.sh | bash`

## 🌐 Access

`longhorn-up.sh` already applied the `HTTPRoute` (its step `[3/3]`). To re-apply it alone:

```bash
kubectl apply -f _k8s/longhorn/httproute.yaml
```

> 🌐 **Domain**: the manifest carries the neutral domain `kubeadm.lab.example.io` (public repo).
> `longhorn-up.sh` substitutes `LAB_DOMAIN` on the fly; applying the file by hand, as above,
> keeps the neutral domain. Substitute it yourself:
>
> ```bash
> sed 's/kubeadm\.lab\.example\.io/kubeadm.lab.my-domain.tld/g' \
>   _k8s/longhorn/httproute.yaml | kubectl apply -f -
> ```
>
> (see [`../README.md`](../README.md#-lab_domain--the-ui-domain)).

| Interface | URL / command | Auth |
|---|---|---|
| Longhorn UI (HTTPS via `main-gateway`) | `https://longhorn.kubeadm.lab.example.io` | **none** |
| Without exposing it | `kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80` | — |

The wildcard cert `*.kubeadm.lab.example.io` is already carried by the `https` listener: nothing
to issue here, whichever TLS mode the lab runs (self-signed by default, or cert-manager — the
Secret has the same name either way, see [`../self-signed/README.md`](../self-signed/README.md)).

> ⚠️ **The Longhorn UI has no authentication whatsoever.** Exposed like this, it is reachable by
> anyone who can reach the VIP (over Tailscale) — and it lets them delete volumes. To protect it:
> an Envoy Gateway `SecurityPolicy` (Basic Auth / OIDC) targeting this `HTTPRoute`.

## ⚠️ Pitfalls

- **`defaultReplicaCount` > number of storage nodes** → volumes stuck `Degraded`, forever.
  `longhorn-up.sh` aligns it on the nodes it counts; if you install the chart by hand, set it
  yourself (with 1 worker, `1`).
- **Two default StorageClasses** if `../local-path-storage/` is installed too: `values.yaml`
  sets `persistence.defaultClass: true` (⇒ `longhorn`) and `local-path-storage.yaml` annotates
  `local-path` with `is-default-class: "true"`. A PVC without `storageClassName` then becomes
  **non-deterministic**. Pick a single default:
  ```bash
  kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class-
  # or, the other way around: helm upgrade ... --set persistence.defaultClass=false
  ```
- **`iscsid` stopped** (or a node built outside `kubeadm/provision.sh`) → CSI pods in
  `CrashLoopBackOff`, `iscsiadm: not found` / `Failed to execute iscsiadm`. Fix on the node:
  `sudo apt-get install -y open-iscsi && sudo systemctl enable --now iscsid`.
- **`multipath-tools` (`multipathd`)**: Debian 13 does **not** install it, and that is exactly
  why Longhorn works out of the box here. If you install it for something else, `multipathd`
  grabs Longhorn's block devices and volumes fail to attach (`failed to get devicemapper`).
  Blacklist them in `/etc/multipath.conf` (`devices { device { vendor "IET" ... } }`) or leave
  the package out.
- **Shared disk**: Longhorn on `/var/lib/longhorn` eats the same filesystem as the OS, the
  container images and etcd → watch for `DiskPressure`, prefer `longhorn-r1`, or move to a
  dedicated disk (above).
- **`vagrant destroy` of a worker destroys its replicas.** On `longhorn` (3 replicas) Longhorn
  rebuilds elsewhere; on `longhorn-r1` (1 replica) **the data is gone**. Drain and let Longhorn
  rebuild before removing a node that stores anything you care about.
- **Uninstall**: flip the Longhorn setting `deleting-confirmation-flag` to `true` before
  `helm uninstall`, otherwise the deletion hangs forever.

## 📚 References

- [Longhorn — Installation requirements (1.12)](https://longhorn.io/docs/1.12.0/deploy/install/#installation-requirements)
- [Longhorn — Quick Installation](https://longhorn.io/docs/1.12.0/deploy/install/)
- `kubeadm/provision.sh` — where `open-iscsi`, `nfs-common` and the `iscsi_tcp` module are set up.
