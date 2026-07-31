<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🔑 `vault-secret-operator/` — secrets Vault synchronisés en `Secret` K8s natifs

> Le **Vault Secrets Operator** (VSO), opérateur officiel HashiCorp : il fait remonter des secrets
> Vault dans des `Secret` Kubernetes standards, en **déclaratif** (des CRD, pas des scripts). Une
> app consomme un `Secret` normal (`envFrom`, `valueFrom`, volume) et **n'a jamais besoin de parler
> à Vault**. Le serveur Vault, lui, est dans `../vault-cluster/`.

## 🎯 À quoi ça sert

Trois intégrations Vault ↔ Kubernetes existent. Ce dossier monte celle qui est recommandée :

| Intégration | Modèle | Verdict 2026 |
|---|---|---|
| **Vault Secrets Operator (VSO)** | CRD → `Secret` K8s natif, rotation + rollout | ✅ **recommandé** (ce dossier) |
| Vault CSI Provider | volume monté, aucun `Secret` K8s créé | ok si on refuse tout secret dans etcd |
| Agent Injector (sidecar) | annotations + un sidecar par pod | ⚠️ legacy / maintenance |

VSO gagne parce qu'il est **GitOps-friendly** (les CRD sont versionnables, les valeurs non), qu'il
couvre **static / dynamic / PKI** avec un seul opérateur, qu'il détecte la **dérive** (drift →
resync), qu'il **renouvelle** les leases des creds dynamiques et qu'il **redémarre** les workloads
incapables de recharger un `Secret` à chaud.

### Un contrat en miroir

L'intégration se câble **des deux côtés** : une identité prouvée côté K8s doit correspondre à une
identité autorisée côté Vault. Chaque sous-dossier documente sa moitié.

```
┌─────────────────────── Kubernetes (dossier k8s/) ───────────────────────┐
│  ServiceAccount  ──(token JWT projeté, audience "vault")──┐              │
│        ▲                                                  ▼              │
│  Deployment app        VaultAuth ── VaultConnection ── VSO (opérateur)   │
│        ▲  envFrom            │                            │              │
│   Secret K8s ◄── VaultStaticSecret / VaultDynamicSecret / VaultPKISecret │
└──────────────────────────────────────────┬──────────────────────────────┘
                                            │ login kubernetes + lecture
┌───────────────────────────────────────── ▼ ─── Vault (dossier vault/) ──┐
│  auth/kubernetes  ──(TokenReview valide le JWT)──►  role  ──►  policy    │
│                                                                 │        │
│  kv-v2 (static) · database (dynamic) · pki (certs) · transit (cache) ◄───┘│
└───────────────────────────────────────────────────────────────────────┘
```

Le maillon de confiance est le **`ServiceAccount`** K8s : VSO présente son token JWT, Vault le
valide via l'API **TokenReview** du cluster, et si le SA + le namespace + l'audience correspondent
au **role** configuré, Vault renvoie un token porteur de la **policy** — donc des droits de lecture
précis, et rien de plus.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| Serveur Vault **descellé** | tout part de là | `vault status` → `Sealed false` |
| Adresse Vault atteignable du cluster | le `VaultConnection` par défaut vise `http://vault.vault.svc.cluster.local:8200` | `kubectl -n vault get svc vault` |
| API K8s joignable **par Vault** | validation TokenReview. In-cluster : `https://kubernetes.default.svc`. Vault externe : la VIP `https://192.168.56.5:6443` (portée par keepalived, cf. `kubeadm/provision.sh`) | `vault read auth/kubernetes/config` |
| `helm` + `kubectl` | install de l'opérateur, application des CR | `helm version` |
| CLI `vault` sur l'hôte | lancer les scripts de `vault/` | `vault version` |

<details>
<summary>Installer le CLI <code>vault</code> (Ubuntu, dépôt HashiCorp)</summary>

```bash
wget -qO- https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com noble main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y vault
```

La dist `noble` fournit un binaire générique, valable sur une Ubuntu plus récente.
</details>

## ⚡ Installation

L'ordre compte : **Vault d'abord** (l'identité doit exister avant qu'un client tente de se logger),
puis l'opérateur, puis les CR.

```bash
# 1. Côté Vault : auth kubernetes + moteurs + policies + roles      -> voir vault/LISEZ-MOI.md
export VAULT_ADDR=https://vault.kubeadm.lab.example.io
export VAULT_TOKEN=<root-token>                                  # cf. ../vault-cluster/LISEZ-MOI.md
./_k8s/vault-secret-operator/vault/kubeadm-lab.sh

# 2. L'opérateur (chart épinglé en 1.5.0)
helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace vault-secrets-operator --create-namespace \
  --version 1.5.0 \
  -f _k8s/vault-secret-operator/values.yaml
kubectl -n vault-secrets-operator rollout status deploy/vault-secrets-operator-controller-manager

# 3. Les CR côté cluster                                            -> voir k8s/LISEZ-MOI.md
kubectl apply -f _k8s/vault-secret-operator/k8s/nginx-test-vault/nginx-test-vault.yaml
```

Chart **1.5.0** = app version **1.5.0**. Pas de `*-up.sh` ici : les deux moitiés s'installent
séparément et dans cet ordre.

## 🔧 Ce que règle `values.yaml`

| Réglage | Valeur | Effet |
|---|---|---|
| `defaultVaultConnection.enabled` | `true` | pose **un** `VaultConnection` nommé `default` sur `http://vault.vault.svc.cluster.local:8200` : les CR n'ont plus à répéter l'adresse |
| `defaultVaultConnection.skipTLSVerify` | `false` | pas de contournement TLS (on parle en HTTP en interne, cf. `../vault-cluster/`) |
| `defaultAuthMethod.enabled` | `false` | on préfère un `VaultAuth` explicite par namespace (`k8s/02-vaultauth.yaml`) : plus lisible, multi-tenant |
| `clientCache.persistenceModel` | `none` | cache en **RAM**, aucune dépendance au moteur Transit. Suffisant pour du statique |
| `clientCache.storageEncryption.enabled` | `false` | pas de cache chiffré (découle du point précédent) |
| `telemetry.serviceMonitor.enabled` | `false` | à passer à `true` si l'opérateur Prometheus et ses CRD sont installés (cf. `../observability/`) |

Le jour où on synchronise de vrais creds **dynamiques**, repasser en
`persistenceModel: direct-encrypted` + `storageEncryption.enabled: true` (+ moteur Transit et role
`vso-transit`, déjà préparés dans `vault/`) — voir le piège sur `storageEncryption` plus bas.

## ✅ Vérifier

```bash
kubectl -n vault-secrets-operator get pods
kubectl -n vault-secrets-operator logs deploy/vault-secrets-operator-controller-manager -f
kubectl get vaultconnection -A                  # le "default" posé par values.yaml
kubectl get vaultauth,vaultstaticsecret,vaultdynamicsecret,vaultpkisecret -A
```

Les vérifications par scénario sont dans `k8s/LISEZ-MOI.md`, celles côté serveur dans
`vault/LISEZ-MOI.md`.

## 🧪 Scénarios

### 1. Secret KV du lab → variables d'env → redémarrage auto (`nginx-test-vault`)

Le chemin concret et testé : un moteur KV-v2 **`kubeadm-lab/`** avec **un sous-dossier par appli**, et
une démo nginx qui prouve la boucle complète.

```bash
./_k8s/vault-secret-operator/vault/kubeadm-lab.sh                     # config Vault
kubectl apply -f _k8s/vault-secret-operator/k8s/nginx-test-vault/nginx-test-vault.yaml

# La rotation, en direct : on change la valeur dans Vault…
vault kv put kubeadm-lab/nginx-test-vault/config \
  APP_GREETING="Bonjour depuis Vault" APP_COLOR=green APP_SECRET_TOKEN=v2
# …VSO resync (refreshAfter 30s) -> Secret mis à jour -> rolloutRestartTargets relance le Deployment
kubectl -n nginx-test-vault rollout status deploy/nginx-test-vault
```

Détail des objets créés : `k8s/LISEZ-MOI.md`. Détail de la config Vault : `vault/LISEZ-MOI.md`.

### 2. Rotation du mot de passe PostgreSQL par Vault (static role)

Vault gère et **fait tourner** le mot de passe d'un utilisateur PostgreSQL existant, et le workload
consommateur est **redémarré automatiquement** à chaque rotation. Le serveur PG est le cluster
CloudNativePG `pg-demo` (cf. `../cloudnative-pg/`).

> ℹ️ **Static role ≠ dynamic role.** Un **dynamic role** (`<mount>/creds/<role>`) fait *créer* par
> Vault un user éphémère au nom aléatoire, révoqué à l'expiration du lease — le username change à
> chaque fois. Un **static role** (`<mount>/static-roles/<role>`) prend en gestion un user
> **existant et fixe** et n'en rotate que le **mot de passe** : la chaîne de connexion reste stable.
> C'est ce second mode qui est monté ici.

```
Vault (admin postgres) ──rotate password──► user PG « vault-rotate »
        │  database/static-creds/vault-rotate  (username + password courant + ttl)
        ▼
VSO (VaultDynamicSecret allowStaticCreds) ──SecretTransformation──► Secret K8s pg-rotate-creds
        │   DATABASE_URL + PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD
        ▼
Deployment alpine (envFrom) ── rolloutRestartTargets ──► RELANCÉ à chaque rotation
```

**Prérequis spécifiques** (dans l'ordre) :

> ⚠️ **Le cluster PostgreSQL doit être UP.** Toute la boucle en dépend : Vault s'y connecte en admin
> pour rotater le mot de passe, et l'app s'y connecte avec les creds. Si `pg-demo` est absent ou
> arrêté, l'écriture de `database/config/…` échoue, les rotations tombent en erreur et le Secret
> n'est pas (re)généré.
> ```bash
> kubectl -n cnpg-demo get cluster pg-demo    # "Cluster in healthy state", 3/3 instances
> ```

```bash
# a. Accès superuser (Vault se connecte en admin "postgres" pour rotater le password)
kubectl -n cnpg-demo patch cluster pg-demo --type=merge \
  -p '{"spec":{"enableSuperuserAccess":true}}'

# b. Base "vault" + user "vault-rotate" créés une fois dans PG
PRIMARY=$(kubectl -n cnpg-demo get pods \
  -l cnpg.io/cluster=pg-demo,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
# mot de passe bootstrap : il sera immédiatement remplacé par Vault
kubectl -n cnpg-demo exec "$PRIMARY" -c postgres -- psql -c \
  "CREATE ROLE \"vault-rotate\" WITH LOGIN PASSWORD 'bootstrap-temp-pw';"
kubectl -n cnpg-demo exec "$PRIMARY" -c postgres -- psql -c \
  "CREATE DATABASE vault OWNER \"vault-rotate\";"
```

**Mise en route :**

```bash
export VAULT_ADDR=http://127.0.0.1:8200   # kubectl -n vault port-forward svc/vault-active 8200:8200
export VAULT_TOKEN=<root-token>
# ROTATION_PERIOD réglable (défaut 3h ; 2m pour observer la boucle en direct)
./_k8s/vault-secret-operator/vault/pg-dynamic-rotate.sh
kubectl apply -f _k8s/vault-secret-operator/k8s/pg-dynamic-rotate/pg-dynamic-rotate.yaml
```

**Observer la rotation → le redémarrage :**

```bash
vault read database/static-creds/vault-rotate       # username fixe, password + ttl qui bougent
vault write -f database/rotate-role/vault-rotate    # forcer une rotation immédiate
kubectl -n pg-rotate-demo get deploy pg-rotate-demo -o jsonpath='{.metadata.generation}'; echo
kubectl -n pg-rotate-demo get pods -l app=pg-rotate-demo -w
```

Ce que le script écrit dans Vault : `vault/LISEZ-MOI.md`. Les objets K8s : `k8s/LISEZ-MOI.md`.

> ⚠️ **Chaque rotation = un rollout du consommateur.** Avec `ROTATION_PERIOD=2m`, le pod alpine
> redémarre toutes les 2 minutes ; remonter la période après la démo.

> ℹ️ **Sécurité / lab** : Vault se connecte en **superuser `postgres`**, le plus simple. En prod,
> préférer un role d'admin dédié à privilèges réduits (juste de quoi `ALTER ROLE … PASSWORD`), et
> envisager `database/rotate-root` pour que Vault rotate aussi son propre mot de passe admin.

## 🛡️ Les CRD et les bonnes pratiques appliquées

| CRD | Rôle | Exemple |
|---|---|---|
| `VaultConnection` | **Où** est Vault (adresse, CA, TLS) | `values.yaml` / `k8s/01-vaultconnection.yaml` |
| `VaultAuth` | **Comment** s'authentifier (méthode, mount, role, SA, audience) | `k8s/02-vaultauth.yaml` |
| `VaultAuthGlobal` | `VaultAuth` **mutualisé** entre namespaces (DRY, multi-tenant) | `k8s/03-vaultauthglobal.yaml` |
| `VaultStaticSecret` | Synchronise un secret **KV** (v1/v2) → `Secret` | `k8s/10-static-kv.yaml` |
| `VaultDynamicSecret` | Creds **éphémères** (DB, cloud…) + renouvellement de lease ; aussi les **static roles** | `k8s/20-dynamic-db.yaml` |
| `VaultPKISecret` | Émet et **renouvelle** un certificat TLS (moteur `pki`) | `k8s/30-pki-tls.yaml` |
| `SecretTransformation` | **Templating** : reformate les données avant écriture du `Secret` | `k8s/40-secrettransformation.yaml` |
| `HCPAuth` / `HCPVaultSecretsApp` | Variante **HCP Vault Secrets** (SaaS) — hors lab | — |

- **Moindre privilège par policy** : une policy = un usage (kv / db / pki), scopée au chemin exact.
  Aucun wildcard de mount. Cf. `vault/policies/`.
- **Un role Vault par app**, bindé à des `bound_service_account_names`/`_namespaces` précis (jamais
  `*`), avec une **audience dédiée** (`vault`) et un **`token_ttl` court** (15m ici) : un token volé
  expire vite et ne vaut que pour Vault.
- **`refreshAfter` proportionnel à la sensibilité** (static) et **`renewalPercent`** (dynamic), pour
  renouveler avant expiration du lease.
- **`rolloutRestartTargets` systématique** : sans lui, un secret roté n'atteint jamais le process.
- **GitOps** : versionner les CR, **jamais** les valeurs. VSO écrit les `Secret`, git ne les voit
  pas.
- **RBAC sur les `VaultAuth`** : c'est une porte d'entrée vers Vault. En multi-tenant,
  `VaultAuthGlobal` + `allowedNamespaces` cadrent qui peut s'en servir.

## ⚠️ Pièges

- **`storageEncryption.role` est au mauvais niveau dans `values.yaml` (ligne 55).** Il y est frère
  de `method`/`mount`/`transitMount`/`keyName`, alors que le chart `vault-secrets-operator` 1.5.0
  l'attend sous `controller.manager.clientCache.storageEncryption.**kubernetes**.role`. Tel quel, la
  valeur est **ignorée** en silence et le role vaut `""`. Sans conséquence aujourd'hui
  (`storageEncryption.enabled: false`), mais bloquant dès qu'on active le cache chiffré : à corriger
  **avant** de passer en `direct-encrypted`.
  ```bash
  helm show values hashicorp/vault-secrets-operator --version 1.5.0   # la structure de référence
  ```
- **Login refusé (`permission denied` / `403`)** : le SA ou le namespace du pod ne correspond pas au
  role Vault (`bound_service_account_*`), ou l'audience ne matche pas
  (`VaultAuth.spec.kubernetes.audiences` doit être dans les `audience` du role). C'est 90 % des
  cas — le test de login « à blanc » de `vault/LISEZ-MOI.md` l'isole en une commande.
- **Vault ne peut pas valider le JWT** : `auth/kubernetes/config` mal renseigné. Vault
  **in-cluster** : son SA doit avoir `system:auth-delegator` (le chart le fait via
  `server.authDelegator.enabled=true`). Vault **externe** : `kubernetes_host` +
  `kubernetes_ca_cert` + `token_reviewer_jwt` sont tous les trois obligatoires. Et attention au bug
  de `vault/01-kubernetes-auth.sh` documenté dans `vault/LISEZ-MOI.md`.
- **`disable_iss_validation`** : `true` par défaut depuis Vault 1.9 — ne pas le repasser à `false`
  avec des tokens projetés courts (l'`iss` varie), sinon tous les logins cassent.
- **Secret jamais mis à jour dans le pod** : il manque `rolloutRestartTargets`. Le `Secret` K8s est
  bien à jour (`kubectl get secret` le prouve) ; c'est le process qui garde l'ancienne valeur.
- **Creds dynamiques orphelins après un crash de l'opérateur** : le cache client est en mémoire
  (`persistenceModel: none`), donc les leases sont perdus au redémarrage et Vault garde des creds
  actifs que plus personne ne réclame. Acceptable pour du statique, pas pour du dynamique.
- **CA TLS de Vault** : en HTTPS avec une CA privée, fournir `caCertSecretRef` au `VaultConnection`,
  sinon `x509: certificate signed by unknown authority`. `skipTLSVerify: true` = lab uniquement.
- **La démo `k8s/20-dynamic-db.yaml` est cassée par un décalage de mount** (`db` vs `database`) :
  détail et correctif dans `vault/LISEZ-MOI.md`.

## 📚 Références

- [Vault Secrets Operator — vue d'ensemble](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso)
- [VSO — installation Helm](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/installation)
- [VSO — API reference (CRD)](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/api-reference)
- [VSO — dépôt GitHub (releases, samples)](https://github.com/hashicorp/vault-secrets-operator)
- [Kubernetes auth method](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [VSO déclaratif — guide 2026 (oneuptime)](https://oneuptime.com/blog/post/2026-02-09-vault-secrets-operator-declarative/view)
