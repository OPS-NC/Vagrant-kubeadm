<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# ☸️ `_k8s/` — the lab's application layer

> Everything that gets installed **after** the cluster bootstrap, with `kubectl`/`helm` from
> the host — **including the CNI**: `kubeadm init` never installs a pod network, so the nodes
> stay `NotReady` until step `[1/4]` of `platform-up.sh` has run.

Read this directory in two passes: a **base platform** (4 components, a single script), then
**independent addons** you add opt-in, each in its own directory with its own `*-up.sh`.

## ⚡ Quick start

```bash
# 1. Bootstrap with CNI=cilium (the repo default): kubeadm installs no CNI, this layer does
CNI=cilium ./kubeadm/cluster-up.sh

# 2. The base platform: Cilium → Envoy Gateway → metrics-server → wildcard TLS
./_k8s/platform-up.sh

# 3. The addons, opt-in
./_k8s/longhorn/longhorn-up.sh      # block storage (StorageClass longhorn)
./_k8s/vault-cluster/vault-up.sh    # Vault HA — needs longhorn-up.sh first
./_k8s/argocd/argocd-up.sh
./_k8s/chaos-kube/chaoskube-up.sh    # optional: chaos, deletes 1 pod/hour
```

> ⚠️ **`CNI=cilium` is the only "everything on" choice.** This layer needs a `LoadBalancer`
> Service that really gets an IP: that is exactly what Cilium's L2 announcement (ARP) does.
> With `flannel`, `calico` or `none`, the Gateway stays at `EXTERNAL-IP <pending>` and **no UI
> is reachable**.

## 🌐 Choosing the CNI

`CNI` (in `lab.env`) is read in two places: `kubeadm/cluster-up.sh` records it in
`_out/cluster.env` (and uses it to decide whether to skip the `kube-proxy` addon), then
`platform-up.sh` reads that file back and installs the CNI.

| `CNI=` | Who installs the CNI | LoadBalancer IP (L2) | Usable for this layer |
|---|---|---|---|
| **`cilium`** *(default)* | `platform-up.sh` → [`cilium/`](cilium/README.md) | ✅ pool + ARP announcement | ✅ yes |
| `calico` | `platform-up.sh` → [`calico/`](calico/README.md) | ❌ BGP only | ⚠️ MetalLB required on top |
| `flannel` | `platform-up.sh` (`flannel/flannel` chart, inline) | ❌ | ❌ no |
| `none` | you | ❌ | depends on what you install |

> ⚠️ **`KUBE_PROXY_REPLACEMENT=true` requires `CNI=cilium`.** With `true`, `kubeadm init` ran
> with `--skip-phases=addon/kube-proxy` and only Cilium can take over in eBPF. Both
> `cluster-up.sh` and `platform-up.sh` refuse the other combinations: without kube-proxy *and*
> without a replacement, not a single ClusterIP answers — CoreDNS included.

> ⚠️ **Switching CNI on an existing cluster is not supported**: `./kubeadm/cluster-reset.sh`
> (or `vagrant destroy`), then rebuild. Two CNIs at once fight over the pod network.

## 🔗 Dependency chain

Every link assumes the previous one: no LoadBalancer IP without an L2 announcer, no HTTPS
without the Gateway, no UI without a certificate on the `:443` listener.

```
cluster bootstrapped  (./kubeadm/cluster-up.sh — nodes NotReady, no CNI yet)
   │
   ├─ 1. CNI              cilium/ (default, + L2 pool → LoadBalancer IP .200)
   │                      or calico/ (CNI only) or flannel (CNI only) or nothing
   ├─ 2. envoy-gateway/   Envoy controller + main-gateway (listeners :80 and :443)
   ├─ 3. metric-server    metrics.k8s.io API  (kubectl top, HPA)
   └─ 4. wildcard TLS     *.kubeadm.lab.example.io — one of two modes, per SELF_SIGNED
              │             true  (default) → self-signed/   openssl, local CA, no cert-manager
              │             false           → cert-manager/  Let's Encrypt DNS-01 Cloudflare
              │
              └─ addons: storage → databases → secrets → observability → security
```

That is exactly the order of `platform-up.sh` (`[1/4]` → `[4/4]`): **metrics-server before
the certificate**. Both TLS modes fill the **same** Secret
(`wildcard-<LAB_DOMAIN with dashes>-tls`), so no addon ever has to know which one you picked
— they all just attach an `HTTPRoute` to the `https` listener.

## 📋 Cross-cutting prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| Cluster `Ready`, `KUBECONFIG` set | every script probes `/readyz` | `kubectl get nodes` |
| `kubectl` + `helm` | chart installs | `helm version` |
| `main-gateway` in place | every UI exposed over HTTPS goes through it | `kubectl get gateway -n envoy-gateway-system` |
| `openssl` on the host — **only if `SELF_SIGNED=true`** (the default) | generates the wildcard TLS | `openssl version` |
| `CLOUDFLARE_API_TOKEN` in `lab.env` — **only if `SELF_SIGNED=false`** | DNS-01 for the TLS wildcard | read by `platform-up.sh` |
| `LAB_DOMAIN` in `lab.env` | UI domain (TLS wildcard + `HTTPRoute`) | `sed -n 's/^LAB_DOMAIN=//p' lab.env` |
| StorageClass, depending on the addon | `local-path`, `longhorn` or `longhorn-r1` | `kubectl get sc` |

> 💡 The StorageClasses are not interchangeable: `longhorn-r1` (1 replica) is the base for
> apps that **already replicate** at the application level (PostgreSQL, Vault), `longhorn`
> (3 replicas) for everything else, `local-path` for anything ephemeral. See
> [`longhorn/`](longhorn/README.md) and [`local-path-storage/`](local-path-storage/README.md).

## 🌐 `LAB_DOMAIN` — the UI domain

The repo is **public**: every versioned manifest carries a **neutral** domain,
`kubeadm.lab.example.io`. Put yours in `lab.env` (gitignored):

```bash
echo 'LAB_DOMAIN=kubeadm.lab.my-domain.tld' >> lab.env
```

The `*-up.sh` scripts (`platform-up.sh`, `argocd-up.sh`, `kyverno-up.sh`,
`observability-up.sh`, `minio-up.sh`, `minio-cluster-up.sh`, `trivy-operator-up.sh`,
`vault/00-secrets-engines.sh`) read `LAB_DOMAIN` — environment variable first, then `lab.env`,
then the neutral default — and substitute the domain **on the fly**:

```bash
sed "s/kubeadm\.lab\.example\.io/${LAB_DOMAIN}/g" <manifest> | kubectl apply -f -
```

No versioned file is rewritten: `git status` stays clean.

> ⚠️ **Manifests applied by hand** (without a `*-up.sh`) get no such substitution:
> `wordpress-example/wordpress-mariadb.yaml`, `longhorn/httproute.yaml`,
> `vault-cluster/httproute.yaml`, `vault-secret-operator/k8s/30-pki-tls.yaml`. Either edit
> them, or pipe them through the same `sed`:
> ```bash
> sed 's/kubeadm\.lab\.example\.io/kubeadm.lab.my-domain.tld/g' <file> | kubectl apply -f -
> ```

> ℹ️ **`SELF_SIGNED` decides how that domain gets its certificate** (see `lab.env.example`).
> `true` — the **default** — signs a wildcard with `openssl` under a local CA
> ([`self-signed/`](self-signed/README.md)): no real domain, no token, no quota, and the
> domain never has to resolve publicly. `false` switches to
> [`cert-manager/`](cert-manager/README.md) + Let's Encrypt, and only then do the three ACME
> variables matter: `LAB_DNS_ZONE` (zone of the DNS-01 solver; default = the last 2 labels of
> `LAB_DOMAIN`), `LAB_ACME_EMAIL` (Let's Encrypt account; default `admin@<zone>`) and
> `LAB_ACME_ISSUER` — `staging` (default, untrusted cert) or `prod` (trusted, but capped at
> **5 certificates per week** for the same wildcard, and every `vagrant destroy` burns one).

## 🧱 Base platform — `platform-up.sh`

Installs **only** the 4 components above, idempotent (`helm upgrade --install`), re-runnable
without breaking anything.

| Component | Pinned version | Where the pin lives |
|---|---|---|
| Cilium | `1.20.0` | `lab.env` (`CILIUM_VERSION`), fallback in `cilium/cilium-up.sh` |
| Envoy Gateway | `1.8.3` | `platform-up.sh` (`ENVOY_GW_VERSION`) |
| metrics-server | `v0.9.0` | `metric-server.yaml` |
| cert-manager — **only if `SELF_SIGNED=false`** | `v1.20.2` | `platform-up.sh` (`CERT_MANAGER_VERSION`) |

> ℹ️ With the default `SELF_SIGNED=true`, step `[4/4]` runs
> [`self-signed/selfsigned-up.sh`](self-signed/README.md) instead and **cert-manager is never
> installed** — no chart, no CRDs, no Cloudflare Secret.

> ℹ️ **metrics-server and `--kubelet-insecure-tls`**: on kubeadm the kubelet's *serving*
> certificate is self-signed (not signed by the cluster CA), so metrics-server cannot verify
> it. The clean alternative — `serverTLSBootstrap: true` plus a CSR approver — is out of scope
> for a throwaway lab. Check: `kubectl top nodes`.

## 🗂️ The addons

Suggested order: storage first (everything else depends on it), then the databases, then the
rest in any order.

### 💾 Storage

| Directory | Purpose | Install | StorageClass provided |
|---|---|---|---|
| [`longhorn/`](longhorn/README.md) | distributed block storage; **needs `open-iscsi` + `iscsid` on the nodes** (installed by `kubeadm/provision.sh`) | `longhorn-up.sh` | `longhorn`, `longhorn-r1` |
| [`local-path-storage/`](local-path-storage/README.md) | dynamic local storage (hostPath), without Longhorn | `local-path-up.sh` | `local-path` |
| [`minio-s3/`](minio-s3/README.md) | S3 object storage + console, **1 node** | `minio-up.sh` | — (consumes `local-path`) |
| [`minio-s3/cluster/`](minio-s3/cluster/README.md) | **distributed** MinIO, 4 nodes, EC:2 erasure coding — the backup target | `minio-cluster-up.sh` | — (consumes `local-path`) |

### 🐘 Databases

| Directory | Purpose | Install | Prerequisites |
|---|---|---|---|
| [`cloudnative-pg/`](cloudnative-pg/README.md) | PostgreSQL HA operator `0.29.0` (app v1.30.0) + 3-node demo cluster, automatic failover, **S3 backups + PITR** | `cloudnative-pg-up.sh` | SC `longhorn-r1`; backups → `minio-s3/cluster` |

### 🔐 Secrets

| Directory | Purpose | Install | Prerequisites |
|---|---|---|---|
| [`vault-cluster/`](vault-cluster/README.md) | HashiCorp Vault HA (Raft), 3 nodes, UI/API under `vault.kubeadm.lab.example.io` | `vault-up.sh` | SC `longhorn`; manual unsealing |
| [`vault-secret-operator/`](vault-secret-operator/README.md) | Vault secrets → native K8s `Secret`s (static KV, dynamic DB, PKI) — both the Vault **and** the K8s side | Helm + `vault/` scripts | `vault-cluster` unsealed |

### 📈 Observability

| Directory | Purpose | Install | Prerequisites |
|---|---|---|---|
| [`observability/`](observability/README.md) | kube-prometheus-stack `87.19.0` + Loki `7.1.0` + Alloy `1.11.0`; `grafana` / `prometheus` / `alertmanager` UIs | `observability-up.sh` | SC `longhorn-r1`; CP ≥ 4 GB |
| [`node-problem-detector/`](node-problem-detector/README.md) | node health (kernel, runtime) `2.3.14` | `node-problem-detector-up.sh` | — |
| [`chaos-kube/`](chaos-kube/README.md) | chaos engineering: chaoskube `0.39.0` deletes **1 random pod/hour**, except `kube-system`, `longhorn-system`, `vault`, `cnpg-demo` | `chaoskube-up.sh` | — |

### 🛡️ Security

| Directory | Purpose | Install | Prerequisites |
|---|---|---|---|
| [`kyverno/`](kyverno/README.md) | policy engine `3.8.2` (app v1.18.2) + Policy Reporter `3.8.1` (UI), teaching policies in Audit mode | `kyverno-up.sh` | `main-gateway` |
| [`trivy-operator/`](trivy-operator/README.md) | continuous scanner `0.34.0` (CVEs, config, secrets, RBAC); reports in the Policy Reporter UI | `trivy-operator-up.sh` | `kyverno` (shared UI) |

### 🌐 Networking & TLS

| Directory | Purpose | Install |
|---|---|---|
| [`cilium/`](cilium/README.md) | **default CNI** `1.19.6` + LoadBalancer IP pool + L2 announcement (ARP) | `cilium-up.sh`, called by `platform-up.sh` when `CNI=cilium` |
| [`calico/`](calico/README.md) | **alternative CNI** `v3.32.1` (Tigera operator) — CNI **only**, no L2 announcement | `calico-up.sh`, called by `platform-up.sh` when `CNI=calico` |
| [`envoy-gateway/`](envoy-gateway/README.md) | Envoy Gateway controller + `main-gateway` (`:80` and `:443` wildcard) + demo apps | `platform-up.sh` |
| [`self-signed/`](self-signed/README.md) | **default TLS mode** — wildcard signed by a local CA (`openssl`), no domain and no token needed | `selfsigned-up.sh`, called by `platform-up.sh` when `SELF_SIGNED=true` |
| [`cert-manager/`](cert-manager/README.md) | automatic wildcard TLS certificates (ACME DNS-01 Cloudflare) | `platform-up.sh`, when `SELF_SIGNED=false` |

### 🧪 Demos

| Directory | Purpose | Install |
|---|---|---|
| [`argocd/`](argocd/README.md) | Argo CD `10.2.1` (GitOps), UI under `argo.kubeadm.lab.example.io` | `argocd-up.sh` |
| [`wordpress-example/`](wordpress-example/README.md) | WordPress + MariaDB on Longhorn, exposed through Envoy | `kubectl apply` |
| `databasement/` | *(local addon, not versioned — see `.gitignore`)* | `databasement-up.sh` |

## 🌍 Remote access (Tailscale + Cloudflare)

The `.200` VIP is a **host-only** IP announced over ARP: reachable from the host, not routable
as-is.

1. **L3** — the host advertises the route:
   ```bash
   sudo tailscale up --advertise-routes=192.168.56.200/32
   ```
   Then approve it in the Tailscale console.
   > ⚠️ Stay on the `/32` (or fence it with an ACL): a `/24` would also expose the Kubernetes
   > API (`:6443`) and SSH on every node.

2. **Name + TLS** — public Cloudflare wildcard `*.kubeadm.lab.example.io → 192.168.56.200`, in
   **DNS-only (grey cloud)**: the Cloudflare proxy cannot reach a private `192.168.56.x` IP.
   TLS is therefore terminated by **Envoy**, not by Cloudflare → the Gateway must carry a
   **publicly trusted** certificate (Let's Encrypt, see `cert-manager/`). A *Cloudflare Origin
   CA* certificate would be rejected by browsers.

## ⚠️ Pitfalls

- **Two default StorageClasses.** `longhorn/values.yaml` sets `persistence.defaultClass:
  true` and `local-path-storage.yaml` sets the `is-default-class: "true"` annotation. With
  both addons installed ⇒ a PVC without an explicit `storageClassName` lands on the most
  recently created SC, non-deterministically. Always name your SC.
- **The repo's own Kyverno policies are violated by the repo.** `require-requests-limits`
  demands a `limits.cpu` that the in-house manifests never set (deliberate choice: no CPU
  throttling), and `require-labels` expects `app.kubernetes.io/name` where they use `app:`.
  The report is therefore noisy by construction — see
  [`kyverno/`](kyverno/README.md).
- **Metric emitters are off by default.** `serviceMonitor`/`podMonitor` are `false` in
  trivy-operator, CloudNativePG and node-problem-detector: Prometheus scrapes nothing from
  them until you flip them on after installing observability.
- **Never lower `CP_MEM` below `3072`.** Stacking these addons on 2 GB control planes starves
  etcd. `lab.env.example` ships `4096`, which is what `observability/` requires.
- **A `git add -A` can publish local addon secrets.** `_k8s/databasement/` is gitignored for
  that very reason — check `git status` before committing.

## 📚 References

- [`../README.md`](../README.md) — the kubeadm/Vagrant lab, from `vagrant up` to a ready cluster
- [`../kubeadm/UPGRADE.md`](../kubeadm/UPGRADE.md) — upgrading Kubernetes
- [Gateway API](https://gateway-api.sigs.k8s.io/) ·
  [Cilium](https://docs.cilium.io/) ·
  [Envoy Gateway](https://gateway.envoyproxy.io/) ·
  [cert-manager](https://cert-manager.io/docs/)
