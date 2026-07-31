<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🐘 `cloudnative-pg/` — declarative PostgreSQL HA (CloudNativePG operator)

> **One `Cluster` CRD = one complete PostgreSQL HA setup.** The operator watches that object and
> reconciles the actual state: it creates the pods, mounts the PVCs, elects a primary, attaches
> streaming replicas, and **fails over on its own** if the primary dies. The textbook case of the
> *operator* pattern.

## 🎯 Purpose

- Demonstrate the **operator pattern**: you describe the desired state, the controller does the
  rest (provisioning, replication, **automatic failover**, rolling updates, backups).
- Show a **live failover** — a 30 s demo (see 🧪 Scenarios).
- Give the other components a **real database**: credentials rotated by Vault
  (`../vault-secret-operator/`), S3 backups to MinIO (`../minio-s3/cluster/`).

What gets deployed: the operator (1 pod, ns `cnpg-system`) plus a demo cluster `pg-demo`
(ns `cnpg-demo`, 3 instances = 1 primary + 2 replicas, 1Gi RWO PVCs on `longhorn-r1`).

### Two layers of resilience (keep them apart when teaching)

1. **PostgreSQL replication** (logical): the primary streams its WAL to 2 replicas →
   application-level failover if the primary is lost.
2. **Longhorn replication** (block): a PVC can be replicated by Longhorn across several
   nodes → survives the loss of a disk.

These are **two independent mechanisms**. **This lab's choice: 1 Longhorn replica** for the
database PVCs (dedicated `longhorn-r1` StorageClass), because PostgreSQL already replicates at
the application level — stacking 3 block replicas × 3 instances = 9 copies of the same dataset,
which fills up the shared OS disk (~20 GB). If a node dies, **CNPG rebuilds** the lost instance
from the primary. That is the recommended pattern for a database operator on Longhorn, and a good
hook for explaining "application replication vs storage replication" — and *when not to double
up*.

## 📋 Prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| **Longhorn** (`../longhorn/`) | provides the CSI that provisions the PVCs | `kubectl -n longhorn-system get pods` |
| **`longhorn-r1`** StorageClass (`../longhorn/longhorn-r1-storageclass.yaml`) | storage for the 3 instances; the script **aborts** (`exit 1`) if it is missing | `kubectl get sc longhorn-r1` |
| **3 workers** | the default anti-affinity places 1 instance per worker | `kubectl get nodes` |

> ℹ️ **`longhorn-r1` is not created by this component.** `cluster-demo.yaml` only
> **references** it; it is defined in `_k8s/longhorn/longhorn-r1-storageclass.yaml`.
> With fewer than 3 workers, lower `instances` in `cluster-demo.yaml` (otherwise one pod stays
> `Pending`).

## ⚡ Install

```bash
kubectl apply -f _k8s/longhorn/longhorn-r1-storageclass.yaml   # if not already done
./_k8s/cloudnative-pg/cloudnative-pg-up.sh
```

Version pinned in the script: chart **`cnpg/cloudnative-pg` 0.29.0** (app **v1.30.0**),
overridable with `CNPG_VERSION=…`. Idempotent (`helm upgrade --install` + `kubectl apply`).

## 🔧 What the script does

1. checks `kubectl`/`helm`, the apiserver, and that the `longhorn-r1` SC is present;
2. installs the **operator** in `cnpg-system` with `values.yaml`, then waits for the rollout;
3. applies `cluster-demo.yaml` (namespace `cnpg-demo` + `Cluster` `pg-demo`) and waits for
   `condition=Ready` (300 s max, without failing if the deadline is exceeded).

### Files

| File | Purpose |
|---------|------|
| `values.yaml` | Helm values for the operator (1 replica, `podMonitorEnabled: false`) |
| `cluster-demo.yaml` | Namespace `cnpg-demo` + `Cluster` `pg-demo` (3 instances, 1Gi RWO on `longhorn-r1`, `max_connections=100`, `shared_buffers=128MB`) |
| `cloudnative-pg-up.sh` | Installs the operator + applies the demo cluster |
| `pg-backup-vault-s3.yaml` / `pg-backup-up.sh` | Hourly **logical** backup (`pg_dump`) to MinIO, with the Vault creds |
| `pg-app-backup-cnpg.yaml` / `pg-app-backup-cnpg-up.sh` | **Native CNPG** backup (physical + WAL, PITR) to MinIO |

### What the operator creates for you

| Resource | Purpose |
|-----------|------|
| `Secret pg-demo-app` | Application credentials (`user`, `password`, `dbname`, `host`, `uri`) |
| `Service pg-demo-rw` | Read/write → **always the primary** |
| `Service pg-demo-ro` | Read-only → **replicas** (read load balancing) |
| `Service pg-demo-r`  | All nodes (primary + replicas) |
| `Secret pg-demo-superuser` | **Only if `enableSuperuserAccess: true`** — absent by default (see ⚠️ Pitfalls) |

## ✅ Verify

```bash
kubectl -n cnpg-demo get cluster pg-demo                       # READY 3/3, "Cluster in healthy state"
kubectl -n cnpg-demo get pods -l cnpg.io/cluster=pg-demo       # pg-demo-1/2/3 Running, 1 per worker
kubectl -n cnpg-demo get pvc                                   # 3 PVCs Bound, 1Gi longhorn-r1

# Connect and read (through the primary pod)
kubectl -n cnpg-demo exec -it pg-demo-1 -- psql -c '\l'        # lists the databases (including `app`)
```

The `kubectl-cnpg` plugin gives a richer view (install it on the host, optional):

```bash
kubectl cnpg status pg-demo -n cnpg-demo
```

## 🧪 Scenarios

### 1. Automatic failover (the showstopper)

```bash
kubectl -n cnpg-demo get cluster pg-demo -o jsonpath='{.status.currentPrimary}'; echo  # e.g. pg-demo-1
kubectl -n cnpg-demo delete pod pg-demo-1                       # kill the primary
watch kubectl -n cnpg-demo get cluster pg-demo                  # a replica is promoted within seconds
```

The operator promotes a replica and recreates the old primary as a replica, with no intervention.

### 2. Persistence on Longhorn

Write some data, delete a pod: the PVC is reattached, the data survives. Delete the node (VM):
CNPG rebuilds the instance from the primary (with `longhorn-r1` the block is **not** replicated
elsewhere — PostgreSQL is what catches up, see the two layers above).

### 3. Consuming the database from an app

The `Secret pg-demo-app` holds a ready-to-use `uri`. Ideal for wiring up a demo app, or for
pairing with **Vault**/VSO for rotated credentials (see `../vault-secret-operator/`).

```bash
kubectl -n cnpg-demo get secret pg-demo-app -o jsonpath='{.data.uri}' | base64 -d; echo
```

### 4. Scaling the replicas

```bash
kubectl -n cnpg-demo patch cluster pg-demo --type merge -p '{"spec":{"instances":2}}'  # 3→2
# (scale back to 3 afterwards; watch the rebalancing)
```

## 💽 Backups — two mechanisms living side by side

Both push to **MinIO** and therefore require the **`../minio-s3/cluster/`** component (namespace
`minio-cluster`, Secret `minio-creds`: both scripts read the MinIO root password and create a
bucket plus a dedicated user through a `port-forward`).

| | `pg_dump`-via-Vault (`pg-backup-vault-s3.yaml`) | **Native CNPG** (`pg-app-backup-cnpg.yaml`) |
|---|---|---|
| Goes through the CNPG CRDs | ❌ no (plain CronJob) | ✅ yes (`Backup` / `ScheduledBackup`) |
| Type | Logical (`pg_dump \| gzip`) | **Physical** (base backup + WAL archiving) |
| Scope | 1 database (`vault`) | The whole `pg-demo` instance (including `app`) |
| PG credentials | **Vault** (`pg-rotate-creds`, rotated) | CNPG-internal |
| Frequency | CronJob `0 * * * *` (hourly) | `ScheduledBackup` `0 0 * * * *` (hourly) + continuous WAL |
| PITR (restore to a point in time) | ❌ no | ✅ yes |
| Bucket / retention | `pg-backups` — **no expiration** | `cnpg-backups` — `retentionPolicy: 7d` |

### A. Hourly logical backup through the Vault credentials

`pg_dump` backup of the `vault` database, every hour, pushed to the `pg-backups` bucket —
connecting to PostgreSQL with the credentials **rotated by Vault**.

```
CronJob pg-backup-vault-s3 (ns pg-rotate-demo, schedule "0 * * * *")
   │  pg_dump "$DATABASE_URL"  (Vault creds from Secret pg-rotate-creds, sslmode=require)
   ▼  vault-<timestamp>.sql.gz
   └─ mc cp ──► MinIO bucket pg-backups   (dedicated MinIO user pg-backup, scoped to the bucket)
```

Prerequisites on top of MinIO: **Vault rotation already in place** (Secret `pg-rotate-creds` in
`pg-rotate-demo` — the script refuses to go on without it) and the `pg-demo` cluster UP.

```bash
./_k8s/cloudnative-pg/pg-backup-up.sh     # MinIO bucket + user + Secret minio-backup-creds + CronJob
# Trigger an immediate backup to check:
kubectl -n pg-rotate-demo create job pg-backup-now --from=cronjob/pg-backup-vault-s3
kubectl -n pg-rotate-demo logs job/pg-backup-now
```

> ⚠️ **This backup does NOT go through the CloudNativePG CRDs.** No `Backup`/`ScheduledBackup`,
> no `barmanObjectStore`: it is a `pg_dump` carried by a plain CronJob, chosen **on purpose** so
> it can use the Vault creds — something the native CNPG backup cannot do.

### B. Native CloudNativePG backup (CRD → MinIO, with PITR)

**Physical** backup of the whole `pg-demo` instance (`app` database included) + **continuous WAL
archiving**, pushed by barman-cloud. Enables **point-in-time restore**.

```
Cluster pg-demo  ── spec.backup.barmanObjectStore ──►  MinIO bucket cnpg-backups/pg-demo/
   ├─ base/<timestamp>/data.tar.gz   (base backup, triggered by Backup/ScheduledBackup)
   └─ wals/.../*.gz                  (CONTINUOUS WAL archiving => PITR)
ScheduledBackup pg-demo-hourly  ── "0 0 * * * *" (6-field cron: sec min h …) ──► base backups
```

```bash
# dedicated MinIO bucket/user + Secret cnpg-backup-s3 + barmanObjectStore patch
# (+ retentionPolicy 7d) + ScheduledBackup + 1 immediate backup
./_k8s/cloudnative-pg/pg-app-backup-cnpg-up.sh

# Verify
kubectl -n cnpg-demo get backups                       # phase=completed, method=barmanObjectStore
kubectl -n cnpg-demo get cluster pg-demo \
  -o jsonpath='{.status.firstRecoverabilityPoint}{"\n"}'   # PITR starting point (not empty)
mc ls -r <alias>/cnpg-backups/pg-demo/                 # base/… + wals/…
```

> 💡 **Restore (PITR)**: you create a **new** `Cluster` with `spec.bootstrap.recovery` pointing at
> the same `barmanObjectStore` (+ `recoveryTarget` for a point in time). You do not restore
> "into" the existing cluster. See the CNPG "Recovery" docs.

## 🚑 Troubleshooting

- **Cluster stuck at `Creating a new replica`** → normal provisioning (bootstrap + join);
  allow 2-5 min. Otherwise check the PVCs (`kubectl -n cnpg-demo get pvc`) and Longhorn.
- **A replica stays `Pending`** → the anti-affinity wants 1 instance per worker: not enough
  workers. Lower `instances` or add a worker (`WORKERS` in `lab.env`).
- **PVC `Pending`** → `longhorn-r1` StorageClass missing, or Longhorn down (see `../longhorn/`).
- **Volumes `Degraded` on the Longhorn side** → Longhorn `defaultReplicaCount` > number of
  workers.
- **`pg-backup-up.sh`: "secret pg-rotate-creds missing"** → Vault rotation is not in place: run
  through `../vault-secret-operator/` (rotation section) first.
- **CNPG backup stuck in `running`/`failed`** → check the archiving condition:
  `kubectl -n cnpg-demo get cluster pg-demo -o jsonpath='{.status.conditions}'`
  (`ContinuousArchiving` must be `True`), then the logs of the primary instance's sidecar.

## ⚠️ Pitfalls

- **Longhorn `faulted` / `ReplicaSchedulingFailure: insufficient storage`** — *already hit on
  this lab*: with `default-replica-count=3` and the shared OS disk (~20 GB), 3 block replicas
  × 3 instances do not fit. Hence `longhorn-r1`. Diagnosis:
  `kubectl -n longhorn-system get volume <pvc> -o jsonpath='{.status.conditions}'`.
- **No `pg-demo-superuser` Secret by default.** Since CNPG 1.21, `enableSuperuserAccess`
  defaults to **`false`** and `cluster-demo.yaml` does not set it back: the Secret therefore does
  **not** exist. But `../vault-secret-operator/vault/pg-dynamic-rotate.sh` reads it to configure
  Vault's `database/` engine → it **fails on the first run**. Do this first:
  ```bash
  kubectl -n cnpg-demo patch cluster pg-demo --type=merge \
    -p '{"spec":{"enableSuperuserAccess":true}}'
  ```
- **The `pg-backups` bucket has NO expiration rule at all.** The CronJob is hourly → **~8,760
  objects a year**, on a MinIO bucket sitting on `local-path` (4 × 10Gi, EC:2) and with no quota.
  Nothing prunes it, neither the script nor the manifest. In a lab: keep an eye on it, or add a
  lifecycle rule by hand on the MinIO side (`mc ilm rule add`, see the MinIO docs). The
  **native** backup, on the other hand, is bounded (`retentionPolicy: "7d"` set by
  `pg-app-backup-cnpg-up.sh`).
- **The CronJob downloads `mc` from the Internet on EVERY run.**
  `pg-backup-vault-s3.yaml` does a `wget https://dl.min.io/…/mc` inside the container, **with no
  pinned version and no checksum verification**: with no outbound access (or if `dl.min.io`
  moves), the hourly backup fails. Your rescue path therefore depends on the Internet —
  acceptable in a lab, to be replaced by an image that ships `mc` for real.
- **In-tree `barmanObjectStore` is deprecated.** On CNPG **1.30** it still works but its removal
  is announced for **1.31.0**. Migration path: the **Barman Cloud Plugin** (CNPG-I, an
  `ObjectStore` object + `plugin` on the `Cluster`). The principle (base + WAL → S3/MinIO, PITR)
  is identical; only the declaration changes.
- **No metrics in Prometheus**: that is expected, everything is off by default. After installing
  `../observability/`, set `monitoring.enablePodMonitor: true` in `cluster-demo.yaml` (instance
  metrics) **and** `monitoring.podMonitorEnabled: true` in `values.yaml` (operator metrics), then
  re-run the script. The `PodMonitor` CRD only exists after kube-prometheus-stack — hence the
  order.

## 📚 References

- [CloudNativePG — Documentation](https://cloudnative-pg.io/documentation/current/)
- [CloudNativePG — Cluster (API)](https://cloudnative-pg.io/documentation/current/cloudnative-pg.v1/)
- [CloudNativePG — Backup to S3 object storage](https://cloudnative-pg.io/documentation/current/backup/)
- [CloudNativePG — Barman Cloud Plugin (successor to the in-tree one)](https://github.com/cloudnative-pg/plugin-barman-cloud)
- Related addons: `../longhorn/` (`longhorn-r1` SC) · `../minio-s3/cluster/` (backup target) ·
  `../vault-secret-operator/` (credential rotation) · `../observability/` (metrics)
