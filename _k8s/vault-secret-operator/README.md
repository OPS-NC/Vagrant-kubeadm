<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🔑 `vault-secret-operator/` — Vault secrets synced into native K8s `Secret` objects

> The **Vault Secrets Operator** (VSO), HashiCorp's official operator: it surfaces Vault secrets
> as standard Kubernetes `Secret` objects, **declaratively** (CRDs, not scripts). An app consumes
> a plain `Secret` (`envFrom`, `valueFrom`, volume) and **never needs to talk to Vault**. The
> Vault server itself lives in `../vault-cluster/`.

## 🎯 Purpose

Three Vault ↔ Kubernetes integrations exist. This directory sets up the recommended one:

| Integration | Model | 2026 verdict |
|---|---|---|
| **Vault Secrets Operator (VSO)** | CRD → native K8s `Secret`, rotation + rollout | ✅ **recommended** (this directory) |
| Vault CSI Provider | mounted volume, no K8s `Secret` created | fine if you refuse any secret in etcd |
| Agent Injector (sidecar) | annotations + one sidecar per pod | ⚠️ legacy / maintenance |

VSO wins because it is **GitOps-friendly** (CRDs are versionable, values are not), because it
covers **static / dynamic / PKI** with a single operator, because it detects **drift** (drift →
resync), because it **renews** the leases of dynamic creds and because it **restarts** the
workloads that cannot reload a `Secret` live.

### A mirrored contract

The integration is wired **on both sides**: an identity proven on the K8s side must match an
authorized identity on the Vault side. Each subdirectory documents its own half.

```
┌────────────────────── Kubernetes (k8s/ directory) ──────────────────────┐
│  ServiceAccount  ──(projected JWT token, audience "vault")──┐            │
│        ▲                                                    ▼            │
│  app Deployment        VaultAuth ── VaultConnection ── VSO (operator)    │
│        ▲  envFrom            │                              │            │
│   K8s Secret ◄── VaultStaticSecret / VaultDynamicSecret / VaultPKISecret │
└──────────────────────────────────────────┬──────────────────────────────┘
                                            │ kubernetes login + read
┌───────────────────────────────────────── ▼ ── Vault (vault/ directory) ─┐
│  auth/kubernetes  ──(TokenReview validates the JWT)──►  role  ──► policy │
│                                                                    │     │
│  kv-v2 (static) · database (dynamic) · pki (certs) · transit (cache) ◄───┘│
└───────────────────────────────────────────────────────────────────────┘
```

The trust link is the K8s **`ServiceAccount`**: VSO presents its JWT token, Vault validates it
through the cluster's **TokenReview** API, and if the SA + the namespace + the audience match the
configured **role**, Vault returns a token carrying the **policy** — so precise read rights, and
nothing more.

## 📋 Prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| Vault server **unsealed** | everything starts there | `vault status` → `Sealed false` |
| Vault address reachable from the cluster | the default `VaultConnection` targets `http://vault.vault.svc.cluster.local:8200` | `kubectl -n vault get svc vault` |
| K8s API reachable **by Vault** | TokenReview validation. In-cluster: `https://kubernetes.default.svc`. External Vault: the VIP `https://192.168.56.5:6443` (carried by keepalived, see `kubeadm/provision.sh`) | `vault read auth/kubernetes/config` |
| `helm` + `kubectl` | install the operator, apply the CRs | `helm version` |
| `vault` CLI on the host | run the scripts in `vault/` | `vault version` |

<details>
<summary>Install the <code>vault</code> CLI (Ubuntu, HashiCorp repo)</summary>

```bash
wget -qO- https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com noble main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y vault
```

The `noble` distribution ships a generic binary, which also works on a more recent Ubuntu.
</details>

## ⚡ Install

Order matters: **Vault first** (the identity must exist before a client tries to log in), then
the operator, then the CRs.

```bash
# 1. Vault side: kubernetes auth + engines + policies + roles       -> see vault/README.md
export VAULT_ADDR=https://vault.kubeadm.lab.example.io
export VAULT_TOKEN=<root-token>                                  # see ../vault-cluster/README.md
./_k8s/vault-secret-operator/vault/kubeadm-lab.sh

# 2. The operator (chart pinned to 1.5.0)
helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace vault-secrets-operator --create-namespace \
  --version 1.5.0 \
  -f _k8s/vault-secret-operator/values.yaml
kubectl -n vault-secrets-operator rollout status deploy/vault-secrets-operator-controller-manager

# 3. The CRs on the cluster side                                    -> see k8s/README.md
kubectl apply -f _k8s/vault-secret-operator/k8s/nginx-test-vault/nginx-test-vault.yaml
```

Chart **1.5.0** = app version **1.5.0**. No `*-up.sh` here: the two halves install separately,
and in that order.

## 🔧 What `values.yaml` settles

| Setting | Value | Effect |
|---|---|---|
| `defaultVaultConnection.enabled` | `true` | creates **one** `VaultConnection` named `default` on `http://vault.vault.svc.cluster.local:8200`: the CRs no longer have to repeat the address |
| `defaultVaultConnection.skipTLSVerify` | `false` | no TLS bypass (we speak HTTP internally, see `../vault-cluster/`) |
| `defaultAuthMethod.enabled` | `false` | we prefer an explicit per-namespace `VaultAuth` (`k8s/02-vaultauth.yaml`): more readable, multi-tenant |
| `clientCache.persistenceModel` | `none` | cache in **RAM**, no dependency on the Transit engine. Enough for static secrets |
| `clientCache.storageEncryption.enabled` | `false` | no encrypted cache (follows from the previous point) |
| `telemetry.serviceMonitor.enabled` | `false` | switch to `true` once the Prometheus operator and its CRDs are installed (see `../observability/`) |

The day real **dynamic** creds get synced, switch back to
`persistenceModel: direct-encrypted` + `storageEncryption.enabled: true` (+ the Transit engine and
the `vso-transit` role, already prepared in `vault/`) — see the `storageEncryption` pitfall below.

## ✅ Verify

```bash
kubectl -n vault-secrets-operator get pods
kubectl -n vault-secrets-operator logs deploy/vault-secrets-operator-controller-manager -f
kubectl get vaultconnection -A                  # the "default" created by values.yaml
kubectl get vaultauth,vaultstaticsecret,vaultdynamicsecret,vaultpkisecret -A
```

The per-scenario checks live in `k8s/README.md`, the server-side ones in `vault/README.md`.

## 🧪 Scenarios

### 1. Lab KV secret → env vars → automatic restart (`nginx-test-vault`)

The concrete, tested path: a KV-v2 engine **`kubeadm-lab/`** with **one subdirectory per app**, and
an nginx demo that proves the whole loop.

```bash
./_k8s/vault-secret-operator/vault/kubeadm-lab.sh                     # Vault config
kubectl apply -f _k8s/vault-secret-operator/k8s/nginx-test-vault/nginx-test-vault.yaml

# Rotation, live: change the value in Vault…
vault kv put kubeadm-lab/nginx-test-vault/config \
  APP_GREETING="Bonjour depuis Vault" APP_COLOR=green APP_SECRET_TOKEN=v2
# …VSO resyncs (refreshAfter 30s) -> Secret updated -> rolloutRestartTargets restarts the Deployment
kubectl -n nginx-test-vault rollout status deploy/nginx-test-vault
```

Details of the objects created: `k8s/README.md`. Details of the Vault config: `vault/README.md`.

### 2. PostgreSQL password rotation by Vault (static role)

Vault manages and **rotates** the password of an existing PostgreSQL user, and the consuming
workload is **restarted automatically** on every rotation. The PG server is the CloudNativePG
cluster `pg-demo` (see `../cloudnative-pg/`).

> ℹ️ **Static role ≠ dynamic role.** A **dynamic role** (`<mount>/creds/<role>`) has Vault
> *create* an ephemeral user with a random name, revoked when the lease expires — the username
> changes every time. A **static role** (`<mount>/static-roles/<role>`) takes over an
> **existing, fixed** user and rotates only its **password**: the connection string stays stable.
> It is that second mode that is set up here.

```
Vault (postgres admin) ──rotate password──► PG user "vault-rotate"
        │  database/static-creds/vault-rotate  (username + current password + ttl)
        ▼
VSO (VaultDynamicSecret allowStaticCreds) ──SecretTransformation──► K8s Secret pg-rotate-creds
        │   DATABASE_URL + PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD
        ▼
alpine Deployment (envFrom) ── rolloutRestartTargets ──► RESTARTED on every rotation
```

**Scenario-specific prerequisites** (in order):

> ⚠️ **The PostgreSQL cluster must be UP.** The whole loop depends on it: Vault connects to it as
> admin to rotate the password, and the app connects to it with the creds. If `pg-demo` is missing
> or stopped, writing `database/config/…` fails, rotations error out and the Secret is not
> (re)generated.
> ```bash
> kubectl -n cnpg-demo get cluster pg-demo    # "Cluster in healthy state", 3/3 instances
> ```

```bash
# a. Superuser access (Vault connects as admin "postgres" to rotate the password)
kubectl -n cnpg-demo patch cluster pg-demo --type=merge \
  -p '{"spec":{"enableSuperuserAccess":true}}'

# b. Database "vault" + user "vault-rotate", created once in PG
PRIMARY=$(kubectl -n cnpg-demo get pods \
  -l cnpg.io/cluster=pg-demo,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
# bootstrap password: Vault replaces it right away
kubectl -n cnpg-demo exec "$PRIMARY" -c postgres -- psql -c \
  "CREATE ROLE \"vault-rotate\" WITH LOGIN PASSWORD 'bootstrap-temp-pw';"
kubectl -n cnpg-demo exec "$PRIMARY" -c postgres -- psql -c \
  "CREATE DATABASE vault OWNER \"vault-rotate\";"
```

**Bringing it up:**

```bash
export VAULT_ADDR=http://127.0.0.1:8200   # kubectl -n vault port-forward svc/vault-active 8200:8200
export VAULT_TOKEN=<root-token>
# ROTATION_PERIOD is tunable (default 3h; 2m to watch the loop live)
./_k8s/vault-secret-operator/vault/pg-dynamic-rotate.sh
kubectl apply -f _k8s/vault-secret-operator/k8s/pg-dynamic-rotate/pg-dynamic-rotate.yaml
```

**Watching the rotation → the restart:**

```bash
vault read database/static-creds/vault-rotate       # fixed username, password + ttl keep moving
vault write -f database/rotate-role/vault-rotate    # force an immediate rotation
kubectl -n pg-rotate-demo get deploy pg-rotate-demo -o jsonpath='{.metadata.generation}'; echo
kubectl -n pg-rotate-demo get pods -l app=pg-rotate-demo -w
```

What the script writes into Vault: `vault/README.md`. The K8s objects: `k8s/README.md`.

> ⚠️ **Every rotation = a rollout of the consumer.** With `ROTATION_PERIOD=2m`, the alpine pod
> restarts every 2 minutes; raise the period back up after the demo.

> ℹ️ **Security / lab**: Vault connects as **superuser `postgres`**, the simplest option. In
> production, prefer a dedicated admin role with reduced privileges (just enough to
> `ALTER ROLE … PASSWORD`), and consider `database/rotate-root` so Vault also rotates its own
> admin password.

## 🛡️ The CRDs and the good practices applied

| CRD | Role | Example |
|---|---|---|
| `VaultConnection` | **Where** Vault is (address, CA, TLS) | `values.yaml` / `k8s/01-vaultconnection.yaml` |
| `VaultAuth` | **How** to authenticate (method, mount, role, SA, audience) | `k8s/02-vaultauth.yaml` |
| `VaultAuthGlobal` | `VaultAuth` **shared** across namespaces (DRY, multi-tenant) | `k8s/03-vaultauthglobal.yaml` |
| `VaultStaticSecret` | Syncs a **KV** secret (v1/v2) → `Secret` | `k8s/10-static-kv.yaml` |
| `VaultDynamicSecret` | **Ephemeral** creds (DB, cloud…) + lease renewal; also **static roles** | `k8s/20-dynamic-db.yaml` |
| `VaultPKISecret` | Issues and **renews** a TLS certificate (`pki` engine) | `k8s/30-pki-tls.yaml` |
| `SecretTransformation` | **Templating**: reshapes the data before the `Secret` is written | `k8s/40-secrettransformation.yaml` |
| `HCPAuth` / `HCPVaultSecretsApp` | **HCP Vault Secrets** (SaaS) variant — outside the lab | — |

- **Least privilege, one policy at a time**: one policy = one use (kv / db / pki), scoped to the
  exact path. No mount wildcard. See `vault/policies/`.
- **One Vault role per app**, bound to precise `bound_service_account_names`/`_namespaces` (never
  `*`), with a **dedicated audience** (`vault`) and a **short `token_ttl`** (15m here): a stolen
  token expires fast and is only good for Vault.
- **`refreshAfter` proportional to sensitivity** (static) and **`renewalPercent`** (dynamic), to
  renew before the lease expires.
- **`rolloutRestartTargets` everywhere**: without it, a rotated secret never reaches the process.
- **GitOps**: version the CRs, **never** the values. VSO writes the `Secret` objects, git never
  sees them.
- **RBAC on `VaultAuth`**: it is a door into Vault. In multi-tenant setups, `VaultAuthGlobal` +
  `allowedNamespaces` frame who may use it.

## ⚠️ Pitfalls

- **`storageEncryption.role` sits at the wrong level in `values.yaml` (line 55).** There it is a
  sibling of `method`/`mount`/`transitMount`/`keyName`, while the `vault-secrets-operator` 1.5.0
  chart expects it under `controller.manager.clientCache.storageEncryption.**kubernetes**.role`.
  As it stands, the value is **silently ignored** and the role is `""`. No consequence today
  (`storageEncryption.enabled: false`), but blocking as soon as the encrypted cache is turned on:
  fix it **before** switching to `direct-encrypted`.
  ```bash
  helm show values hashicorp/vault-secrets-operator --version 1.5.0   # the reference structure
  ```
- **Login refused (`permission denied` / `403`)**: the pod's SA or namespace does not match the
  Vault role (`bound_service_account_*`), or the audience does not match
  (`VaultAuth.spec.kubernetes.audiences` must be among the role's `audience`). That is 90% of the
  cases — the dry-run login test in `vault/README.md` isolates it in a single command.
- **Vault cannot validate the JWT**: `auth/kubernetes/config` is filled in wrong. Vault
  **in-cluster**: its SA needs `system:auth-delegator` (the chart does it via
  `server.authDelegator.enabled=true`). Vault **external**: `kubernetes_host` +
  `kubernetes_ca_cert` + `token_reviewer_jwt` are all three mandatory. And watch out for the
  `vault/01-kubernetes-auth.sh` bug documented in `vault/README.md`.
- **`disable_iss_validation`**: `true` by default since Vault 1.9 — do not set it back to `false`
  with short projected tokens (`iss` varies), or every login breaks.
- **Secret never updated inside the pod**: `rolloutRestartTargets` is missing. The K8s `Secret` is
  up to date (`kubectl get secret` proves it); it is the process that keeps the old value.
- **Orphaned dynamic creds after an operator crash**: the client cache is in memory
  (`persistenceModel: none`), so the leases are lost on restart and Vault keeps active creds that
  nobody claims any more. Acceptable for static secrets, not for dynamic ones.
- **Vault TLS CA**: over HTTPS with a private CA, give `caCertSecretRef` to the
  `VaultConnection`, otherwise `x509: certificate signed by unknown authority`.
  `skipTLSVerify: true` = lab only.
- **The `k8s/20-dynamic-db.yaml` demo is broken by a mount mismatch** (`db` vs `database`):
  details and fix in `vault/README.md`.

## 📚 References

- [Vault Secrets Operator — overview](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso)
- [VSO — Helm installation](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/installation)
- [VSO — API reference (CRDs)](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/api-reference)
- [VSO — GitHub repo (releases, samples)](https://github.com/hashicorp/vault-secrets-operator)
- [Kubernetes auth method](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [Declarative VSO — 2026 guide (oneuptime)](https://oneuptime.com/blog/post/2026-02-09-vault-secrets-operator-declarative/view)
