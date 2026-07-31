<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🧾 `k8s/` — the CRs **on the Kubernetes side**

> The cluster half of the VSO wiring: the declarative resources the operator watches in order to
> produce Kubernetes `Secret` objects. It is all `kubectl` from here. The server-side counterpart
> (auth, engines, policies, roles) lives in `../vault/`.

## 🎯 The chain of references

```
Vault*Secret ──spec.vaultAuthRef──► VaultAuth ──► VaultConnection (or the "default" from values.yaml)
                                        │
                                        └─► Vault role ──► Vault policy
```

The `VaultAuth` carries the Vault **role**; the role carries the **policy**. One broken link (role
name, SA, namespace, audience, mount) gives `SecretSynced: false` in the CR's events.

## 📋 Prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| VSO operator installed | it is what reconciles the CRs | `kubectl -n vault-secrets-operator get deploy` |
| Vault configured (`../vault/`) | the identity must exist **before** the first login | `vault list auth/kubernetes/role` |
| A reachable `VaultConnection` | `default` created by `../values.yaml`, or `01-vaultconnection.yaml` | `kubectl get vaultconnection -A` |

Overall install order and the big picture: `../README.md`.

## ⚡ Apply

### Path A — the lab demos (tested)

Two self-contained manifests, each in its own namespace. They depend on `../vault/kubeadm-lab.sh`
and `../vault/pg-dynamic-rotate.sh` respectively.

```bash
kubectl apply -f _k8s/vault-secret-operator/k8s/nginx-test-vault/nginx-test-vault.yaml
kubectl apply -f _k8s/vault-secret-operator/k8s/pg-dynamic-rotate/pg-dynamic-rotate.yaml
```

### Path B — the numbered teaching CRs (namespace `demo`)

```bash
kubectl apply -f 00-namespace-rbac.yaml     # ns "demo" + ServiceAccount "vso-app"
kubectl apply -f 01-vaultconnection.yaml    # optional if defaultVaultConnection is on
kubectl apply -f 02-vaultauth.yaml          # 3 VaultAuth: static / dynamic / pki
# 03 = multi-tenant variant (VaultAuthGlobal), INSTEAD OF 02

kubectl apply -f 10-static-kv.yaml          # KV-v2  -> Secret "static-kv"
kubectl apply -f 20-dynamic-db.yaml         # ephemeral DB creds (see ⚠️ Pitfalls: broken mount)
kubectl apply -f 30-pki-tls.yaml            # TLS certificate -> Secret "pki-tls"
kubectl apply -f 40-secrettransformation.yaml  # templating -> Secret "app-env"
kubectl apply -f 50-demo-deployment.yaml    # app consuming the 3 Secrets + taking the rollouts
```

> 🌐 **Domain**: `30-pki-tls.yaml` requests the CN `demo-app.kubeadm.lab.example.io` (the public
> repo's neutral domain). It must stay **inside** the `allowed_domains` of the PKI role, itself
> derived from `LAB_DOMAIN` by `../vault/00-secrets-engines.sh`. If you have your own domain:
> `sed 's/kubeadm\.lab\.example\.io/kubeadm.lab.my-domain.tld/g' 30-pki-tls.yaml | kubectl apply -f -`
> (see [`../../README.md`](../../README.md#-lab_domain--the-ui-domain)).

## 🔧 The files

| File | CRD | What it does exactly |
|---|---|---|
| `00-namespace-rbac.yaml` | `Namespace`, `ServiceAccount` | ns `demo` + SA `vso-app` — must match the `bound_service_account_*` of the Vault roles |
| `01-vaultconnection.yaml` | `VaultConnection` | `vault-conn` in `demo` → `http://vault.vault.svc.cluster.local:8200`, `skipTLSVerify: false` |
| `02-vaultauth.yaml` | `VaultAuth` ×3 | `vault-auth-static` / `-dynamic` / `-pki`: mount `kubernetes`, SA `vso-app`, `audiences: [vault]`, roles `vso-static` / `vso-dynamic` / `vso-pki` |
| `03-vaultauthglobal.yaml` | `VaultAuthGlobal` + `VaultAuth` | shared auth config in `vault-secrets-operator`, `allowedNamespaces: [demo]`; the `VaultAuth` then contributes nothing but its role |
| `10-static-kv.yaml` | `VaultStaticSecret` | `mount: kvv2`, `path: demo/app` → Secret `static-kv`, with `rolloutRestartTargets` on `demo-app` |
| `20-dynamic-db.yaml` | `VaultDynamicSecret` | `mount: db`, `path: creds/demo-app`, `renewalPercent: 67`, `revoke: true` → Secret `dynamic-db` |
| `30-pki-tls.yaml` | `VaultPKISecret` | `mount: pki`, `role: demo`, CN `demo-app.kubeadm.lab.example.io` → Secret `pki-tls` (`tls.crt`/`tls.key`) |
| `40-secrettransformation.yaml` | `SecretTransformation` + `VaultStaticSecret` | the `app-env` transformation (`DATABASE_URL`, `APP_PASSWORD`, `excludeRaw: true`) + the `static-kv-templated` CR that uses it |
| `50-demo-deployment.yaml` | `Deployment` | `busybox:1.36`: `envFrom` on `static-kv`, `env` key by key on `dynamic-db`, volume mounted from `pki-tls` |

### `nginx-test-vault/` — lab KV secret → env vars → rollout

The complete loop, and the easiest one to watch. Objects created (all in the
`nginx-test-vault` ns):

| Object | Detail |
|---|---|
| `Namespace` + `ServiceAccount nginx-test-vault` | the identity the Vault role of the same name expects |
| `VaultAuth nginx-test-vault` | mount `kubernetes`, role `nginx-test-vault`, `audiences: [vault]` |
| `VaultStaticSecret nginx-test-vault-config` | `type: kv-v2`, `mount: kubeadm-lab`, `path: nginx-test-vault/config`, `refreshAfter: 30s`, `hmacSecretData: true` (detects drift without logging the values), `rolloutRestartTargets` → the Deployment |
| `Deployment nginx-test-vault` | `nginx:1.27-alpine`, 2 replicas, `envFrom` on the Secret → `APP_GREETING` / `APP_COLOR` / `APP_SECRET_TOKEN` |

### `pg-dynamic-rotate/` — PostgreSQL password rotated by Vault

Static role: the **username stays fixed**, only the password changes; the consumer is restarted on
every rotation. The matching Vault config is detailed in `../vault/README.md`, the full scenario
(PostgreSQL prerequisites included) in `../README.md`.

| Object | Detail |
|---|---|
| `Namespace` + `ServiceAccount pg-rotate` | identity bound to the Vault role `pg-rotate-demo` |
| `VaultAuth pg-rotate` | mount `kubernetes`, role `pg-rotate-demo`, `audiences: [vault]` |
| `SecretTransformation pg-rotate-dsn` | assembles `DATABASE_URL` + `PGHOST`/`PGPORT`/`PGDATABASE`/`PGUSER`/`PGPASSWORD` |
| `VaultDynamicSecret pg-rotate` | `mount: database`, `path: static-creds/vault-rotate`, `allowStaticCreds: true`; `excludes: [".*"]` to keep **only** the templated keys → Secret `pg-rotate-creds`; `rolloutRestartTargets` → the Deployment |
| `Deployment pg-rotate-demo` | `alpine:3.20`, `envFrom` on `pg-rotate-creds`: the DSN lands in its env vars |

## ✅ Verify

```bash
# Path B (ns demo)
kubectl -n demo get vaultauth,vaultstaticsecret,vaultdynamicsecret,vaultpkisecret
kubectl -n demo describe vaultstaticsecret static-kv     # events: "Secret synced"
kubectl -n demo get secret                               # static-kv, dynamic-db, pki-tls, app-env
kubectl -n demo get secret static-kv -o jsonpath='{.data.password}' | base64 -d ; echo
kubectl -n demo logs deploy/demo-app                     # the injected DB_/APP_ variables

# Path A — nginx: the secret -> env -> rollout loop
kubectl -n nginx-test-vault get vaultstaticsecret nginx-test-vault-config   # SecretSynced=True
POD=$(kubectl -n nginx-test-vault get pod -l app=nginx-test-vault -o jsonpath='{.items[0].metadata.name}')
kubectl -n nginx-test-vault exec "$POD" -- env | grep '^APP_'

# Path A — PostgreSQL: the rendered DSN + the proof of the restart
kubectl -n pg-rotate-demo get secret pg-rotate-creds -o jsonpath='{.data.DATABASE_URL}' | base64 -d; echo
kubectl -n pg-rotate-demo get deploy pg-rotate-demo -o jsonpath='{.metadata.generation}'; echo

# On a sync problem, the source of truth remains the operator logs:
kubectl -n vault-secrets-operator logs deploy/vault-secrets-operator-controller-manager -f
```

## ⚠️ Pitfalls

- **`20-dynamic-db.yaml` cannot sync as it stands.** It asks for `mount: db`, but
  `../vault/00-secrets-engines.sh:19` mounts the `database` engine on **`database/`** (no
  `-path=db`), and the `vso-dynamic-db.hcl` policy only allows `db/creds/demo-app`. Result: a
  systematic `403`/`404`. Fix on the Vault side (`vault secrets enable -path=db database`) and full
  explanation in `../vault/README.md`. The `database` engine **also** needs a connection and a
  `creds/demo-app` role pointing at a real database — both left commented out in the script.
- **`50-demo-deployment.yaml` will not start if one of the 3 Secrets is missing.** No reference is
  marked `optional: true`: without `dynamic-db` (see the previous pitfall) the pod stays in
  `CreateContainerConfigError`, and without `pki-tls` it stays stuck in `ContainerCreating` (volume
  not found). The diagnosis is in `kubectl -n demo describe pod`, not in the logs.
- **`02` and `03` are two alternatives, not two steps.** Applying both creates two `VaultAuth` for
  the same role — pointless, and a source of confusion about which one a CR actually uses.
- **`SecretSynced: false`**: read the CR's event (`kubectl describe`). In practice it is either a
  refused login (role / SA / namespace / audience — see `../vault/README.md`), or a wrong
  `mount`/`path`.
- **The `Secret` changes but the pod does not**: `rolloutRestartTargets` is missing. The K8s
  `Secret` is up to date (`kubectl get secret` proves it), but the process keeps the old value in
  memory.
- **`VaultPKISecret` refused**: `commonName` outside the `allowed_domains` of the PKI role, or a
  requested `ttl` larger than the role's `max_ttl` (72h here).
- **`excludes` + `transformationRefs`**: without `excludes: [".*"]` (or `excludeRaw: true`), the
  rendered Secret **also** contains Vault's raw keys (`username`, `password`, `ttl`…). Handy for
  debugging, best avoided when you want a clean Secret.

## 📚 References

- [VSO — API reference (all the CRDs)](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/api-reference)
- [VSO — `SecretTransformation` / templating](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/secret-transformation)
- [VSO — official examples (GitHub repo)](https://github.com/hashicorp/vault-secrets-operator/tree/main/config/samples)
