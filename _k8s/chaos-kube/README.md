<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🐒 `chaos-kube/` — chaos engineering (chaoskube 0.39)

> Deletes **one random pod per hour**, everywhere except `kube-system`,
> `longhorn-system`, `vault` and `cnpg-demo`. The point is not to break things: it is to prove that what the lab runs
> comes back **on its own**. Anything that does not come back was never really highly
> available.

## 🎯 Purpose

[chaoskube](https://github.com/linki/chaoskube) picks a pod at random on every tick and
deletes it. That single behaviour answers questions no amount of `kubectl get` will:

| Question | What a kill reveals |
|---|---|
| Is this workload actually managed? | a bare pod (no Deployment/StatefulSet) **never comes back** |
| Does the app tolerate losing a replica? | single-replica Deployments = visible downtime |
| Do the PVCs re-attach? | a `longhorn` RWO volume has to follow the pod to its new node |
| Is HA real or on paper? | `../vault-cluster/` survives losing 1 pod — but comes back **sealed**, which is why it is excluded |

Files in this directory:

| File | Purpose |
|---|---|
| `chaoskube-up.sh` | the install: chart, flags, and it prints back the flags actually live in the pod |
| `values.yaml` | Helm values: `interval: 1h`, the namespace exclusions, `no-dry-run` |

## 📋 Prerequisites

The lightest addon of the lab — no storage, no Gateway, no certificate.

| Prerequisite | Why | Verify |
|---|---|---|
| Cluster `Ready`, `KUBECONFIG` set | the script probes `/readyz` | `kubectl get nodes` |
| `helm` in `PATH` | install goes through the upstream chart | `helm version` |
| Something worth killing | on an empty cluster chaoskube has nothing to prove | `kubectl get deploy -A` |

> ℹ️ The chart creates its own `ServiceAccount` + `ClusterRole` (`pods: list, delete` and
> `events: create`, cluster-wide). Broad by nature — that **is** the tool's job.

## ⚡ Install

Pinned versions: chart **0.6.0**, app **v0.39.0**.

```bash
./_k8s/chaos-kube/chaoskube-up.sh
```

Idempotent (`helm upgrade --install`), re-runnable. Two knobs:

```bash
CHAOS_DRY_RUN=1 ./_k8s/chaos-kube/chaoskube-up.sh   # observe only, deletes nothing
CHAOSKUBE_VERSION=0.6.0 ./…                          # pin another chart version
```

The script ends by reading the flags **back out of the Deployment** rather than echoing
`values.yaml`: that is the only proof the exclusions and `--no-dry-run` actually landed in the
pod.

## 🔧 Under the hood

The whole configuration is four flags, from `values.yaml`:

```
--interval=1h
--namespaces=!kube-system,!longhorn-system,!vault,!cnpg-demo
--no-dry-run
--timezone=Pacific/Noumea
```

### The exclusion syntax

`--namespaces` takes a selector-like list where `!ns` means *exclude*, comma-separated. The four
exclusions of this lab are not arbitrary:

- **`kube-system`** — with a single control plane, killing `kube-apiserver`, `etcd`, `coredns`
  or the Cilium agent takes down the *cluster*, not an application. There is no HA to test
  there.
- **`longhorn-system`** — the CSI carries the volumes of everything else. Killing an
  `instance-manager` yanks volumes that are still mounted elsewhere; the damage lands on
  innocent bystanders instead of the pod under test.
- **`vault`** — Raft survives losing a pod, but the pod comes back **sealed** and this lab has
  no auto-unseal. After a few hours all 3 are sealed and Vault is down: that stops being a
  resilience test and becomes a chore (`../vault-cluster/vault-up.sh`, every time).
- **`cnpg-demo`** — the demo Postgres cluster (`Cluster/pg-demo`, see
  `../cloudnative-pg/cluster-demo.yaml`). Note this is the **cluster's** namespace, not the
  operator's: `cnpg-system` stays fair game, since killing the operator interrupts no data path.

Everything else is a target, including `envoy-gateway-system` — since #62 the data plane runs
2 replicas, so a kill there costs nothing (the controller restarts, the other envoy keeps
serving).

### Dry-run is the upstream default

chaoskube ships **dry-run on**: without `--no-dry-run` it logs `would kill …` forever and
deletes nothing. `values.yaml` therefore carries `no-dry-run: ""` — an empty value, because the
chart renders `--<key>` for any key whose value is empty.

Going back to dry-run means **removing that key**, not setting it to `false`: the chart template
emits `--<key>` for any falsy value, so `--set chaoskube.args.no-dry-run=null` leaves the flag in
place (verified with `helm template`), and `--no-dry-run=false` is not a chaoskube flag. That is
why `CHAOS_DRY_RUN=1` renders the values into a temporary file with the line stripped.

## ✅ Verify

```bash
# dryRun=false is the line that matters — dryRun=true means it is only talking
kubectl -n chaos-kube logs deploy/chaoskube | head -5

# the parsed filters, as chaoskube understood them (not as you wrote them)
kubectl -n chaos-kube logs deploy/chaoskube | grep 'setting pod filter'

# the body count, most recent last
kubectl get events -A --field-selector reason=Killing --sort-by=.lastTimestamp
```

Expected on startup: `dryRun=false interval=1h0m0s`, then
`namespaces="!cnpg-demo,!kube-system,!longhorn-system,!vault"` — chaoskube sorts them, so the
order will not match `values.yaml` — then a first `terminating pod`: it kills once at startup,
then every hour.

## 🌐 Access

**No UI, no `HTTPRoute`, no domain**: chaoskube is a control loop, it exposes nothing. It is
observed through its logs and the `Killing` Events it writes on its victims.

| Interface | Command |
|---|---|
| Live log | `kubectl -n chaos-kube logs -f deploy/chaoskube` |
| Victims | `kubectl get events -A --field-selector reason=Killing --sort-by=.lastTimestamp` |

Pause it without uninstalling — the fastest way to stop the bleeding during a debug session:

```bash
kubectl -n chaos-kube scale deploy/chaoskube --replicas=0
```

## ⚠️ Pitfalls

- **Un-excluding `vault` seals it.** It is excluded by default for that reason: Vault survives
  losing a pod (Raft, 3 replicas), but the restarted pod is sealed and stays `0/1` — no
  auto-unseal here. Drop `!vault` from the list and within a few hours all three are sealed and
  Vault is down; recovering means re-running `../vault-cluster/vault-up.sh` after every kill.
- **Excluding a namespace that does not exist is silently fine.** `cnpg-demo` is only there once
  `../cloudnative-pg/` is installed; chaoskube just filters on a name and never complains. So
  the exclusion can be pre-loaded before the addon exists — which is exactly the case here.
- **Dry-run is the upstream default** — the #1 way to believe chaos is running when nothing is
  being deleted. Check `dryRun=false` in the logs, not the manifest.
- **A bare pod never comes back.** chaoskube deletes pods, it does not care what owns them.
  Anything created with a plain `kubectl run` / a `Pod` manifest is gone for good — which is
  precisely the finding, not a bug.
- **chaoskube can kill itself**: its own namespace is not excluded. The Deployment recreates it,
  but the hourly timer restarts from zero, so a self-kill silently skips a round.
- **Single control plane**: `kube-system` is excluded for that reason. Do **not** remove that
  exclusion on this topology (`CONTROL_PLANES=1` in `lab.env`) — there is no second API server
  to take over.
- **`minimum-age` is not set**, so a pod that has just started is a valid target, including one
  in the middle of a rollout. Set `minimum-age: "1h"` in `values.yaml` to only ever hit
  workloads that have settled.
- **The timezone is `Pacific/Noumea`**, matching the lab's `LAB_DOMAIN` (`*.ops.nc`). It only
  affects log timestamps as long as no `excluded-weekdays` / `excluded-times-of-day` is set —
  add either of those and the timezone becomes load-bearing.

## 📚 References

- [chaoskube — flags](https://github.com/linki/chaoskube#flags)
- [chaoskube — Helm chart](https://github.com/linki/chaoskube/tree/master/chart)
- [`../vault-cluster/README.md`](../vault-cluster/README.md) — the unsealing that chaos forces
- [`../node-problem-detector/README.md`](../node-problem-detector/README.md) — the other side of
  the coin: detecting node-level trouble instead of causing it
