<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🔒 `vault-cluster/` — HashiCorp Vault HA (Raft), UI exposed over HTTPS

> The lab's Vault **server**: 3 nodes on **integrated Raft** storage, 1 Longhorn PV per node,
> UI + API over HTTPS at `vault.kubeadm.lab.example.io`. Not to be confused with
> `../vault-secret-operator/`, which is the **client** (it syncs Vault secrets into Kubernetes
> `Secret` objects).

## 🎯 Purpose

A central vault for everything the lab must not store in cleartext: application secrets (KV-v2),
PostgreSQL passwords rotated automatically (`database` engine), internal certificates (`pki`
engine). Consumers never talk to Vault directly — that is the VSO's job.

What gets set up here:

| Component | Lab choice | Where it is decided |
|---|---|---|
| High availability | 3 replicas, **integrated Raft** (no Consul), per-node anti-affinity | `values.yaml` (`server.ha`) |
| Storage | one **2Gi RWO** Longhorn PVC per pod (`data-vault-0/1/2`) | `values.yaml` (`server.dataStorage`) |
| TLS | terminated by **Envoy**; Vault listens over **HTTP** internally (`tls_disable`) | `values.yaml` + `httproute.yaml` |
| `disable_mlock` | `true` — harmless here (kubeadm requires swap off, and `kubeadm/provision.sh` disables it) and avoids requiring `IPC_LOCK` | `values.yaml` (`raft.config`) |
| Agent Injector | **disabled**: we go through the VSO, not through sidecars | `values.yaml` (`injector.enabled`) |
| Audit device | **disabled** (`auditStorage`) — one PVC less | `values.yaml` |

## 📋 Prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| Longhorn (SC `longhorn`) | backs the 3 Raft PVCs | `kubectl get sc` |
| `platform-up.sh` (`main-gateway` + `https` listener) | exposes the UI/API over HTTPS | `kubectl get gateway -n envoy-gateway-system` |
| Wildcard cert `*.kubeadm.lab.example.io` | the `HTTPRoute` has no dedicated `Certificate` | `kubectl -n envoy-gateway-system get certificate` |
| DNS `vault.kubeadm.lab.example.io → 192.168.56.200` | reach the UI from the host | `getent hosts vault.kubeadm.lab.example.io` |
| `jq` on the host | slice up the JSON output of `operator init` | `jq --version` |

See `../longhorn/`, `../envoy-gateway/`, `../cert-manager/`.

## ⚡ Install

```bash
./_k8s/vault-cluster/vault-up.sh
```

Installs the chart, **initializes** Vault, **unseals** the 3 pods and applies the `HTTPRoute`.
Idempotent: it only initializes if Vault is not already initialized, and only unseals the pods
that are actually sealed — so it is also **the command to re-run after a reboot**, which always
brings the pods back sealed (§🔐). `VAULT_CHART_VERSION=…` overrides the chart version.

> 🔐 **The unseal keys and the root token land in `_out/vault-init.json`** (mode `0600`, and
> `_out/` is gitignored). The script never prints them. That file is the **only** copy: lose it
> and Vault is unrecoverable — back it up outside the repo. See §🔐 below.

<details>
<summary>The chart alone, by hand</summary>

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
helm upgrade --install vault hashicorp/vault \
  --namespace vault --create-namespace \
  --version 0.34.0 \
  --values _k8s/vault-cluster/values.yaml
```

</details>

Chart **0.34.0** → image **`hashicorp/vault:2.0.3`** (pinned versions, see the header of
`values.yaml`).

The 3 pods start, then stay **`0/1 Running` and SEALED**: that is expected, the readiness probe
fails as long as Vault is neither initialized nor unsealed.

## 🔐 Initialize + unseal

`vault-up.sh` already did this — the commands below are the manual equivalent, useful to
understand or to recover by hand. 5 unseal keys, **threshold of 3**.

> ⚠️ **`vault-1` and `vault-2` cannot be unsealed straight away.** With integrated Raft they
> start **uninitialized** and only join through `retry_join` once the leader is unsealed;
> unsealing them too early fails with `400 — Vault is not initialized`. `vault-up.sh` waits for
> `initialized=true` on each pod before unsealing it.

```bash
# Init on pod 0 — KEEP THE OUTPUT SOMEWHERE SAFE (keys + root token).
kubectl -n vault exec vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 -format=json > vault-init.json

# Unseal vault-0 (3 distinct keys): it becomes the leader
for i in 0 1 2; do
  kubectl -n vault exec vault-0 -- vault operator unseal \
    "$(jq -r ".unseal_keys_b64[$i]" vault-init.json)"
done

# vault-1 and vault-2 join the Raft (retry_join), then unseal in turn
for p in vault-1 vault-2; do for i in 0 1 2; do
  kubectl -n vault exec $p -- vault operator unseal \
    "$(jq -r ".unseal_keys_b64[$i]" vault-init.json)"
done; done

# Root token:
jq -r .root_token vault-init.json
```

> ⚠️ **`vault-init.json` holds the 5 unseal keys AND the root token.** Never commit it —
> `vault-up.sh` writes it to `_out/vault-init.json` precisely because `_out/` is gitignored.
> Every **pod restart** (chart upgrade, node down, node reboot / `vagrant halt`) brings it back **sealed**:
> re-run `./_k8s/vault-cluster/vault-up.sh` (or unseal by hand with 3 of the 5 keys). A real deployment would use **auto-unseal** (the
> Transit engine of another Vault, or a cloud KMS) — out of scope for the lab.

The UI and the API are exposed by the script's step `[4/4]`. To re-apply that route alone:

```bash
kubectl apply -f _k8s/vault-cluster/httproute.yaml
```

> 🌐 **Domain**: the manifest carries the neutral domain `kubeadm.lab.example.io` (public repo) and
> is not applied by any `*-up.sh`: edit the hostname, or substitute your own domain on the fly:
>
> ```bash
> sed 's/kubeadm\.lab\.example\.io/kubeadm.lab.my-domain.tld/g' \
>   _k8s/vault-cluster/httproute.yaml | kubectl apply -f -
> ```
>
> (see [`../README.md`](../README.md#-lab_domain--the-ui-domain)).

## 🔧 Wiring up the VSO

The VSO (`../vault-secret-operator/`) is already wired to
`http://vault.vault.svc.cluster.local:8200` through the `default` `VaultConnection` from its
`values.yaml`. On the Vault side, what is left is enabling Kubernetes auth, the secrets engines,
the policies and the roles: it is all in `../vault-secret-operator/vault/README.md`.

## ✅ Verify

```bash
kubectl -n vault get pods                                        # 1/1 Running after unseal
kubectl -n vault exec vault-0 -- vault status                      # Sealed=false, HA Mode
kubectl -n vault exec vault-0 -- vault operator raft list-peers   # 3 voters
kubectl -n vault get endpoints vault-active                       # 1 endpoint = the leader
curl -sS -o /dev/null -w '%{http_code}\n' \
  --resolve vault.kubeadm.lab.example.io:443:192.168.56.200 \
  https://vault.kubeadm.lab.example.io/ui/                              # 200
```

## 🌐 Access

| What | Value / command |
|---|---|
| UI (public HTTPS) | <https://vault.kubeadm.lab.example.io> — login method **"Token"** |
| Root token | `jq -r .root_token vault-init.json` |
| API from inside the cluster | `http://vault.vault.svc.cluster.local:8200` (what the VSO consumes) |
| API from the host, without DNS | `kubectl -n vault port-forward svc/vault-active 8200:8200` → `http://127.0.0.1:8200` |

The `HTTPRoute` points at the **`vault-active`** service (the leader only): no 307 redirect
emitted by a standby. The certificate is the wildcard carried by the `https` listener of
`main-gateway` (annotation `cert-manager.io/cluster-issuer`, see
`../envoy-gateway/Envoy-Proxy.yml`). With the default `LAB_ACME_ISSUER=staging` it is **not
publicly trusted**: expect a browser warning, or use `curl -k`. Set `LAB_ACME_ISSUER=prod` for a
trusted cert — mind the **5 certificates/week** cap.

> ⚠️ **The UI is only reachable once Vault is unsealed.** `vault-active` has no endpoint until a
> leader is elected: the route then answers **503**. After a cluster reboot you must **unseal
> every pod manually** (3 keys out of 5) before the UI comes back.

## ⚠️ Pitfalls

- **`longhorn` (3 replicas) under Raft = 9 copies for 3 logical nodes.** `values.yaml:26` uses
  the `longhorn` StorageClass, which replicates **3× at the block level** — while Vault Raft
  already replicates **3× at the application level**. This is exactly the case
  `../longhorn/longhorn-r1-storageclass.yaml` tells you to avoid ("replication already handled at
  the application level"), and that CloudNativePG gets right with `longhorn-r1`. On the shared OS
  disk (~20 GB/node) it feeds `ReplicaSchedulingFailure`. To fix it: set
  `server.dataStorage.storageClass` to `longhorn-r1`. Careful, **a PVC's StorageClass is
  immutable**: you have to delete the 3 `data-vault-*` PVCs, hence **reinitialize Vault** — do it
  before you put anything in there.
- **Manual unsealing, after every reboot.** No auto-unseal in this lab (see §🔐). A pod that
  restarts is an unusable pod until 3 keys have been presented to it.
- **[`../chaos-kube/`](../chaos-kube/README.md) excludes this namespace, and must keep doing so.**
  chaoskube deletes a random pod every hour; Raft survives the loss, but the pod comes back
  **sealed**. Un-exclude `vault` and within a few hours all 3 are sealed and Vault is down —
  recovery is `vault-up.sh` after every single kill.
- **Putting `VAULT_ADDR` / `VAULT_TOKEN` / `VAULT_UNSEAL_KEY_*` in `lab.env` does NOTHING.** No
  script in the repo reads those keys from `lab.env` — the only field picked out of that file is
  `CLOUDFLARE_API_TOKEN`, by an explicit `grep` in `../platform-up.sh` (line 30). The scripts in
  `../vault-secret-operator/vault/` only read the **environment**. To really load `lab.env` into
  your shell:
  ```bash
  set -a; . ./lab.env; set +a      # exports everything the file defines
  vault status                     # must answer Sealed=false
  ```
  `lab.env` is gitignored, but storing unseal keys in it makes it as sensitive as
  `vault-init.json`: same precautions.
- **The data does not survive a PVC purge.** It survives reboots (Longhorn partition), but a
  `helm uninstall` followed by `kubectl delete pvc` destroys the Raft — and with it the whole
  content of the vault, including everything the VSO references.
- **`vault status` returns "standby" on 2 pods out of 3**: that is how HA Raft normally works (a
  single leader). Write commands must target `vault-active`, not `vault-0`.

## 🚑 Troubleshooting

| Symptom | Cause | Action |
|---|---|---|
| Pods stuck `0/1 Running` | Vault sealed (readiness fails) | unseal (see §🔐) |
| Route 503 / `vault-active` with no endpoint | no leader elected → Vault sealed | unseal the 3 pods |
| A pod sealed after a reboot | normal behavior, no auto-unseal | `vault operator unseal` ×3 keys |
| A Raft peer missing | `retry_join` failing (`vault-internal` service) | `vault operator raft list-peers`, pod logs |
| PVC `Pending` | Longhorn cannot place 3 replicas | see the first pitfall (`longhorn-r1`) |

## 📚 References

- [Vault on Kubernetes — Helm chart](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/helm)
- [Integrated Raft (storage)](https://developer.hashicorp.com/vault/docs/configuration/storage/raft)
- [`vault operator init` / `unseal`](https://developer.hashicorp.com/vault/docs/commands/operator/init)
- [Auto-unseal (Transit)](https://developer.hashicorp.com/vault/docs/configuration/seal/transit)
