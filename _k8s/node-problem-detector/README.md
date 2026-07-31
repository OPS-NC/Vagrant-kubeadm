<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🩺 `node-problem-detector/` — node health (NodeConditions + Events)

> **[node-problem-detector](https://github.com/kubernetes/node-problem-detector)** (NPD): a
> DaemonSet that runs on **every node** (control planes included), reads the kernel log and
> reports low-level problems to Kubernetes as **NodeConditions** and **Events**.

## 🎯 Purpose

Directly motivated by the **cp2** incident (frozen guest): NPD would have produced a
`TaskHung`/`OOMKilling` event **visible through `kubectl`**, instead of an opaque bare `NotReady`.

### What it detects (kernel-monitor, via `/dev/kmsg`)

| Kernel signal | Reported as |
|---|---|
| `Killed process … total-vm:…` (OOM killer) | Event `OOMKilling` |
| `task … blocked for more than … seconds` | Event `TaskHung` |
| `unregister_netdevice: waiting for …` | Event `UnregisterNetDevice` |
| NULL pointer dereference / `divide error` | Event `KernelOops` |
| `EXT4-fs error`/`warning`, `Buffer I/O error`, `CE memory read error` | Events `Ext4Error` / `Ext4Warning` / `IOError` / `MemoryReadError` |
| `Remounting filesystem read-only` | Condition **`ReadonlyFilesystem=True`** |
| `task docker:… blocked for more than … seconds` | Condition **`KernelDeadlock=True`** |

NPD keeps these two conditions continuously up to date on every node (`KernelDeadlock`,
`ReadonlyFilesystem`, `False` in normal times): that is what you alert on.

### Lab adaptation (important)

- **kernel-monitor only** (`/config/kernel-monitor.json`, reading `/dev/kmsg`). The chart loads
  *kernel-monitor **+ docker-monitor*** by default: the runtime here is **containerd** (kubeadm),
  there is no Docker socket → that monitor fails. `systemd-monitor` reads journald; systemd does
  exist on Debian 13, but Debian keeps the journal **volatile** (`/run/log/journal`) until
  `/var/log/journal` is created, while the chart only mounts `/var/log` → it would see nothing.
  So `values.yaml` reduces `settings.log_monitors` to kernel-monitor alone.
- **Namespace in PodSecurity `privileged`**: NPD runs `privileged` (access to `/dev/kmsg`).
  kubeadm enforces no level cluster-wide by default, but the script labels the namespace anyway:
  it documents the intent and keeps working if admission is hardened.
- **`NoSchedule/Exists` tolerations** → NPD runs **on the control planes too** (cp1/2/3).

## ⚡ Install

```bash
./_k8s/node-problem-detector/node-problem-detector-up.sh
```

Pinned version: chart **`deliveryhero/node-problem-detector` 2.3.14** (app **v0.8.19**),
overridable with `NPD_VERSION=…`. No prerequisites: no storage, no Gateway, no CRD.

## 🔧 What the script does

1. creates the `node-problem-detector` namespace and labels it
   `pod-security.kubernetes.io/{enforce,warn,audit}=privileged`;
2. installs the chart with `values.yaml` (kernel-monitor only, `privileged`, tolerations,
   metrics on `:20257`) and waits for the DaemonSet.

## ✅ Verify

```bash
kubectl -n node-problem-detector get pods -o wide          # 1 pod per node (CP + workers), 1/1
# Conditions set by NPD (False = healthy):
kubectl get nodes -o json | jq -r '.items[] | .metadata.name as $n
  | .status.conditions[] | select(.type|test("KernelDeadlock|ReadonlyFilesystem"))
  | "\($n)  \(.type)=\(.status)"'
# Logs of one agent (must load ONLY kernel-monitor, 0 errors):
kubectl -n node-problem-detector logs ds/node-problem-detector | grep -E 'kernel-monitor|Problem detector started'
```

## 🧪 Test a detection (optional)

Injecting a test kmsg entry on a node triggers the NPD event. The nodes are ordinary Debian
VMs, so the simplest path is a shell on the node:

```bash
vagrant ssh k8s-w1 -c 'echo "task test:1234 blocked for more than 120 seconds." | sudo tee /dev/kmsg'
kubectl get events -A --field-selector reason=TaskHung
```

## 📈 Metrics

NPD exposes Prometheus metrics on `:20257` (`metrics.enabled: true`), but **the ServiceMonitor is
off**: the CRD only exists after `../observability/`. Once that component is installed, set
`metrics.serviceMonitor.enabled: true` in `values.yaml` and re-run the script →
`problem_counter` / `problem_gauge` counters per problem type.

## ⚠️ Pitfalls

- **`settings.custom_monitors: []` in `values.yaml` does NOTHING.** That key **does not exist**
  in chart 2.3.14: the real keys are `settings.custom_monitor_definitions` (a map of config files
  mounted into `/custom-config`) and `settings.custom_plugin_monitors` (a list, empty by
  default). Helm silently accepts an unknown value → no error, no effect. The comment in the file
  makes it look like an explicit opt-out; in reality the plugin monitors are already empty by
  default, and it is **`log_monitors`** (very much real) that does all the adaptation work.
- **The `KernelDeadlock` condition will (almost) never go `True` on this lab.** In
  `kernel-monitor.json` (v0.8.19) the only permanent rule that raises it is the pattern
  `task docker:\w+ blocked for more than \w+ seconds` — a **`docker`** process, which does not
  exist here either (containerd). A real hang shows up as a **`TaskHung` event** (temporary rule,
  any process), not as a node condition: alert on the **Events**, not only on `KernelDeadlock`.
  `ReadonlyFilesystem`, on the other hand, works normally
  (`Remounting filesystem read-only`).
- **NPD fixes nothing: it makes things visible.** The remedy (cordon/drain, reschedule, reboot,
  auto-remediation) is left to the operator, or to a tool like **Draino** / **Descheduler**.
- **A "total" freeze can slip under the radar.** As on cp2, a guest that freezes without writing
  anything to kmsg leaves no trace: NPD mainly helps with **OOM / I/O / FS / task-hung**
  failures, which do leave a kernel line behind.
- **Writing to `/dev/kmsg` needs root on the node** — trivial here (`vagrant ssh` + `sudo`),
  but the write must happen **on the node whose condition you are watching**: a line injected on
  `k8s-w1` will never show up against `k8s-cp1`.

## 📚 References

- [node-problem-detector (upstream)](https://github.com/kubernetes/node-problem-detector)
- [deliveryhero/node-problem-detector chart](https://github.com/deliveryhero/helm-charts/tree/master/stable/node-problem-detector)
- Related addon: `../observability/` (scraping the NPD metrics, alerting on the NodeConditions)
