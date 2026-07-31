<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🔎 `trivy-operator/` — continuous security scanner (Aqua Trivy Operator)

> **The detective side of the lab's security.** Trivy Operator scans what runs, in a loop
> (images, configs, secrets, RBAC), and writes its findings into **report CRDs**. Policy
> Reporter's `trivy` plugin surfaces them in the **same UI as Kyverno** → a single security
> dashboard.

## 🎯 Purpose

- Answer "**which CVEs are running here, right now**" without a CI pipeline.
- Complement Kyverno: **Kyverno = preventive** (blocks/mutates/generates at admission),
  **Trivy = detective** (scans what already runs). Both share the Policy Reporter UI.
- Provide the raw material for a "vulnerability management" module: reports per workload, filter
  by severity, fixable CVEs only.

### What is scanned (and what is not)

| CRD | Contents | Status in this lab |
|---|---|---|
| `VulnerabilityReport` | **CVEs** in the workload images | ✅ active |
| `ConfigAuditReport` | **misconfigurations** (Pod Security, best practices) | ✅ active |
| `ExposedSecretReport` | **plaintext secrets** found in the images | ✅ active |
| `RbacAssessmentReport` | overly permissive **RBAC** | ✅ active |
| `InfraAssessmentReport` | configuration of the **node** components | ✅ active |
| `ClusterComplianceReport` | cluster-level **CIS / NSA / PSS** compliance | ✅ active |

> ⚠️ **The node-collector needs a privileged pod — THE thing to know here.** The last two
> scanners go through a `node-collector` pod that bind-mounts `/etc/systemd`, `/lib/systemd`,
> `/etc/kubernetes` and requires `hostPID`. Those paths exist and are readable on the Debian 13
> nodes, so both scanners are enabled in `values.yaml`
> (`infraAssessmentScannerEnabled: true`, `clusterComplianceEnabled: true`). But that pod is
> **not** admissible under PodSecurity `baseline`/`restricted`: kubeadm enforces no level
> cluster-wide by default, so it runs as-is — if you harden admission, label the namespace
> `privileged`. On very small VMs, turning both back to `false` is a legitimate trade-off; the
> image / config / secret / RBAC scans are **not** affected either way.

## 📋 Prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| [`../kyverno/`](../kyverno/README.md) installed | it provides **Policy Reporter + the UI**; without it the script says so and carries on — Trivy runs, but the unified UI has no "trivy" source | `helm -n kyverno status policy-reporter` |
| Internet access from the nodes | every scan job downloads the **CVE database** | `kubectl -n trivy-system logs deploy/trivy-operator` |
| A namespace where the node-collector is admissible | it needs `hostPID` + `hostPath`; kubeadm enforces no PodSecurity level by default | `kubectl -n trivy-system get pods` |

## ⚡ Install

```bash
./_k8s/trivy-operator/trivy-operator-up.sh
```

Versions pinned in the script: chart `aqua/trivy-operator` **`0.34.0`** (app **v0.32.0**) and
`policy-reporter` **`3.8.1`** (`TRIVY_OPERATOR_VERSION` / `POLICY_REPORTER_VERSION` can be
overridden). Idempotent.

## 🔧 What the script does

1. installs **Trivy Operator** in `trivy-system` with `values.yaml`, then waits for the rollout;
2. if the `policy-reporter` release exists in `kyverno`, **re-applies** it to enable the `trivy`
   plugin (already declared in `../kyverno/policy-reporter-values.yaml`); otherwise it says so
   and carries on.

### The `values.yaml` settings

| Setting | Value | Why |
|---|---|---|
| `operator.scanJobsConcurrentLimit` | **1** (default: 10) | **serialized** scans: never a CPU/RAM spike on modest VMs |
| `operator.scannerReportTTL` | **30m** | an older report gets re-evaluated → re-scan roughly every 30 min, in waves, then idle |
| `operator.infraAssessmentScannerEnabled` | **true** | the node-collector works on Debian nodes (see the callout) |
| `operator.clusterComplianceEnabled` | **true** | same: compliance aggregates the node data collected above |
| `trivy.mode` | `Standalone` | each job carries its own scan; on a large cluster prefer `builtInTrivyServer: true` (cached CVE database) |
| `trivy.ignoreUnfixed` | **true** | shows only **fixable** CVEs — cuts the noise in a training context |
| `trivy.severity` | `HIGH,CRITICAL` | focus on what is actionable |
| `serviceMonitor.enabled` | **false** | the `ServiceMonitor` CRD does not exist before the observability addon (otherwise the chart fails) |

### Files

| File | Purpose |
|---------|------|
| `values.yaml` | the settings above (serialized scans, node-collector off, less noise) |
| `trivy-operator-up.sh` | installs Trivy + re-enables Policy Reporter's trivy plugin |

## ✅ Verify

Scans start on their own; the first reports land within a few minutes (one job at a time).

```bash
kubectl -n trivy-system get pods                  # trivy-operator Running (+ ephemeral scan-* jobs)
kubectl get vulnerabilityreports -A               # CVEs per workload
kubectl get configauditreports -A                 # config audits
kubectl get exposedsecretreports -A               # exposed secrets
kubectl get rbacassessmentreports -A              # overly permissive RBAC
kubectl -n kyverno get pods | grep trivy-plugin   # policy-reporter-trivy-plugin Running
# unified UI (Kyverno + Trivy): https://kyverno.kubeadm.lab.example.io → "trivy" source
```

Top of the most vulnerable images:

```bash
kubectl get vulnerabilityreports -A -o json | jq -r \
  '.items[] | "\(.report.summary.criticalCount + .report.summary.highCount)\t\(.metadata.namespace)/\(.metadata.name)"' \
  | sort -rn | head
```

## 🧪 Scenarios

### 1. Find the lab's vulnerable images

After a few minutes, the UI ("trivy" source) or the command above lists the **fixable**
HIGH/CRITICAL CVEs per image. Move on to the question that matters: which image to update first,
and to which tag.

### 2. Close the loop, preventive + detective (Kyverno × Trivy)

Trivy **detects** an image on `:latest` or carrying CVEs; Kyverno can **prevent** its admission
(`disallow-latest-tag`, or Cosign signature verification). A clean demo of "I observe → I
prevent". The demo apps in `../envoy-gateway/GW-Example.yml` make perfect guinea pigs (one of
them is on `:latest`).

### 3. Read a `ConfigAuditReport` as a PSS audit

Next to the cluster-wide `ClusterComplianceReport`, `ConfigAuditReport` objects give the
per-workload view: they carry the Pod Security-style checks on every workload.

```bash
kubectl -n kyverno get configauditreports -o json | jq -r \
  '.items[0].report.checks[] | select(.success==false) | "\(.severity)\t\(.checkID)\t\(.title)"'
```

> 💡 **The "CIS compliance scan" scenario works here.** `kubectl get clustercompliancereport`
> lists the `k8s-cis-*`, `k8s-nsa-*`, `k8s-pss-*` definitions shipped by the chart, and their
> `status` **is** populated: the compliance controller is on and the node-collector can read
> `/etc/kubernetes` and the systemd units of the Debian nodes. Expect a few minutes and one
> collector pod per node before the first `status.summary` shows up.

## 📈 Prometheus integration (after the observability addon)

Trivy Operator exposes metrics (vulnerability counters per workload). Once
**kube-prometheus-stack** is installed (the `ServiceMonitor` CRD is present), set
`serviceMonitor.enabled: true` in `values.yaml` and re-run the script: the counters become
scrapable and alertable. See [`../observability/`](../observability/README.md).

## ⚠️ Pitfalls

- **Ghost reports after turning the node-collector off.** If you set
  `infraAssessmentScannerEnabled`/`clusterComplianceEnabled` back to `false`, the
  `InfraAssessmentReport` and `ClusterComplianceReport` objects already written **stay stored,
  frozen**. They give the illusion of an active scan. Clean them up if you want an honest state:
  `kubectl delete infraassessmentreports -A --all`.
- **Scan jobs `Pending` / OOM** → concurrency is already at 1; set
  `trivy.builtInTrivyServer: true` (shared trivy server, cached CVE database) or add RAM.
- **No reports after 10 min** → `kubectl -n trivy-system logs deploy/trivy-operator`; it is
  almost always a job failing to download the CVE database (network, registry, Docker Hub
  rate-limit).
- **Too much noise** → `trivy.severity` and `trivy.ignoreUnfixed` are the two knobs; conversely,
  set `severity: "LOW,MEDIUM,HIGH,CRITICAL"` for a "show everything" demo.
- **Scanning eats network and CPU in waves** (`scannerReportTTL: 30m`). On a loaded lab, stretch
  the TTL (`24h`) rather than disabling the operator.

## 📚 References

- [Trivy Operator — documentation](https://aquasecurity.github.io/trivy-operator/latest/)
- [`aquasecurity/k8s-node-collector`](https://github.com/aquasecurity/k8s-node-collector) — the
  component behind the two node scanners (look at its `hostPath` mounts and its `hostPID`)
- [Policy Reporter — Trivy plugin](https://kyverno.github.io/policy-reporter/)
- [`../kyverno/README.md`](../kyverno/README.md) — the **preventive** side, and the shared UI
