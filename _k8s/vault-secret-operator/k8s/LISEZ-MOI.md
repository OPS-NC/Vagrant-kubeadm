<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🧾 `k8s/` — les CR **côté Kubernetes**

> La moitié cluster du câblage VSO : les ressources déclaratives que l'opérateur surveille pour
> produire des `Secret` Kubernetes. Tout se joue au `kubectl`. Le pendant côté serveur (auth,
> moteurs, policies, roles) est dans `../vault/`.

## 🎯 La chaîne de références

```
Vault*Secret ──spec.vaultAuthRef──► VaultAuth ──► VaultConnection (ou le « default » de values.yaml)
                                        │
                                        └─► role Vault ──► policy Vault
```

Le `VaultAuth` porte le **role** Vault ; le role porte la **policy**. Un maillon cassé (nom de
role, SA, namespace, audience, mount) donne `SecretSynced: false` dans les events du CR.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| Opérateur VSO installé | c'est lui qui réconcilie les CR | `kubectl -n vault-secrets-operator get deploy` |
| Vault configuré (`../vault/`) | l'identité doit exister **avant** le premier login | `vault list auth/kubernetes/role` |
| Un `VaultConnection` joignable | `default` posé par `../values.yaml`, ou `01-vaultconnection.yaml` | `kubectl get vaultconnection -A` |

Ordre global d'installation et vue d'ensemble : `../LISEZ-MOI.md`.

## ⚡ Appliquer

### Parcours A — les démos du lab (testées)

Deux manifestes autonomes, chacun dans son namespace. Ils dépendent de `../vault/kubeadm-lab.sh` et
`../vault/pg-dynamic-rotate.sh` respectivement.

```bash
kubectl apply -f _k8s/vault-secret-operator/k8s/nginx-test-vault/nginx-test-vault.yaml
kubectl apply -f _k8s/vault-secret-operator/k8s/pg-dynamic-rotate/pg-dynamic-rotate.yaml
```

### Parcours B — les CR pédagogiques numérotés (namespace `demo`)

```bash
kubectl apply -f 00-namespace-rbac.yaml     # ns "demo" + ServiceAccount "vso-app"
kubectl apply -f 01-vaultconnection.yaml    # optionnel si defaultVaultConnection est actif
kubectl apply -f 02-vaultauth.yaml          # 3 VaultAuth : static / dynamic / pki
# 03 = variante multi-tenant (VaultAuthGlobal), À LA PLACE de 02

kubectl apply -f 10-static-kv.yaml          # KV-v2  -> Secret "static-kv"
kubectl apply -f 20-dynamic-db.yaml         # creds DB éphémères (voir ⚠️ Pièges : mount cassé)
kubectl apply -f 30-pki-tls.yaml            # certificat TLS -> Secret "pki-tls"
kubectl apply -f 40-secrettransformation.yaml  # templating -> Secret "app-env"
kubectl apply -f 50-demo-deployment.yaml    # app qui consomme les 3 Secret + reçoit les rollouts
```

> 🌐 **Domaine** : `30-pki-tls.yaml` demande un CN `demo-app.kubeadm.lab.example.io` (domaine
> neutre du dépôt public). Il doit rester **dans** l'`allowed_domains` du role PKI, lui-même
> posé depuis `LAB_DOMAIN` par `../vault/00-secrets-engines.sh`. Si tu as ton propre domaine :
> `sed 's/kubeadm\.lab\.example\.io/kubeadm.lab.mon-domaine.tld/g' 30-pki-tls.yaml | kubectl apply -f -`
> (cf. [`../../LISEZ-MOI.md`](../../LISEZ-MOI.md#-lab_domain--le-domaine-des-ui)).

## 🔧 Les fichiers

| Fichier | CRD | Ce qu'il fait exactement |
|---|---|---|
| `00-namespace-rbac.yaml` | `Namespace`, `ServiceAccount` | ns `demo` + SA `vso-app` — doivent matcher `bound_service_account_*` des roles Vault |
| `01-vaultconnection.yaml` | `VaultConnection` | `vault-conn` dans `demo` → `http://vault.vault.svc.cluster.local:8200`, `skipTLSVerify: false` |
| `02-vaultauth.yaml` | `VaultAuth` ×3 | `vault-auth-static` / `-dynamic` / `-pki` : mount `kubernetes`, SA `vso-app`, `audiences: [vault]`, roles `vso-static` / `vso-dynamic` / `vso-pki` |
| `03-vaultauthglobal.yaml` | `VaultAuthGlobal` + `VaultAuth` | config d'auth mutualisée dans `vault-secrets-operator`, `allowedNamespaces: [demo]` ; le `VaultAuth` n'apporte plus que son role |
| `10-static-kv.yaml` | `VaultStaticSecret` | `mount: kvv2`, `path: demo/app` → Secret `static-kv`, avec `rolloutRestartTargets` sur `demo-app` |
| `20-dynamic-db.yaml` | `VaultDynamicSecret` | `mount: db`, `path: creds/demo-app`, `renewalPercent: 67`, `revoke: true` → Secret `dynamic-db` |
| `30-pki-tls.yaml` | `VaultPKISecret` | `mount: pki`, `role: demo`, CN `demo-app.kubeadm.lab.example.io` → Secret `pki-tls` (`tls.crt`/`tls.key`) |
| `40-secrettransformation.yaml` | `SecretTransformation` + `VaultStaticSecret` | transformation `app-env` (`DATABASE_URL`, `APP_PASSWORD`, `excludeRaw: true`) + le CR `static-kv-templated` qui l'utilise |
| `50-demo-deployment.yaml` | `Deployment` | `busybox:1.36` : `envFrom` sur `static-kv`, `env` clé par clé sur `dynamic-db`, volume monté depuis `pki-tls` |

### `nginx-test-vault/` — secret KV du lab → variables d'env → rollout

La boucle complète, la plus simple à observer. Objets créés (tous dans le ns
`nginx-test-vault`) :

| Objet | Détail |
|---|---|
| `Namespace` + `ServiceAccount nginx-test-vault` | l'identité attendue par le role Vault du même nom |
| `VaultAuth nginx-test-vault` | mount `kubernetes`, role `nginx-test-vault`, `audiences: [vault]` |
| `VaultStaticSecret nginx-test-vault-config` | `type: kv-v2`, `mount: kubeadm-lab`, `path: nginx-test-vault/config`, `refreshAfter: 30s`, `hmacSecretData: true` (détecte la dérive sans logguer les valeurs), `rolloutRestartTargets` → le Deployment |
| `Deployment nginx-test-vault` | `nginx:1.27-alpine`, 2 réplicas, `envFrom` sur le Secret → `APP_GREETING` / `APP_COLOR` / `APP_SECRET_TOKEN` |

### `pg-dynamic-rotate/` — mot de passe PostgreSQL roté par Vault

Static role : le **username reste fixe**, seul le mot de passe change ; le consommateur est
relancé à chaque rotation. La config Vault correspondante est détaillée dans `../vault/LISEZ-MOI.md`,
le scénario complet (prérequis PostgreSQL inclus) dans `../LISEZ-MOI.md`.

| Objet | Détail |
|---|---|
| `Namespace` + `ServiceAccount pg-rotate` | identité bindée au role Vault `pg-rotate-demo` |
| `VaultAuth pg-rotate` | mount `kubernetes`, role `pg-rotate-demo`, `audiences: [vault]` |
| `SecretTransformation pg-rotate-dsn` | assemble `DATABASE_URL` + `PGHOST`/`PGPORT`/`PGDATABASE`/`PGUSER`/`PGPASSWORD` |
| `VaultDynamicSecret pg-rotate` | `mount: database`, `path: static-creds/vault-rotate`, `allowStaticCreds: true` ; `excludes: [".*"]` pour ne garder **que** les clés templatées → Secret `pg-rotate-creds` ; `rolloutRestartTargets` → le Deployment |
| `Deployment pg-rotate-demo` | `alpine:3.20`, `envFrom` sur `pg-rotate-creds` : la DSN arrive dans ses variables d'env |

## ✅ Vérifier

```bash
# Parcours B (ns demo)
kubectl -n demo get vaultauth,vaultstaticsecret,vaultdynamicsecret,vaultpkisecret
kubectl -n demo describe vaultstaticsecret static-kv     # events : "Secret synced"
kubectl -n demo get secret                               # static-kv, dynamic-db, pki-tls, app-env
kubectl -n demo get secret static-kv -o jsonpath='{.data.password}' | base64 -d ; echo
kubectl -n demo logs deploy/demo-app                     # les variables DB_/APP_ injectées

# Parcours A — nginx : la boucle secret -> env -> rollout
kubectl -n nginx-test-vault get vaultstaticsecret nginx-test-vault-config   # SecretSynced=True
POD=$(kubectl -n nginx-test-vault get pod -l app=nginx-test-vault -o jsonpath='{.items[0].metadata.name}')
kubectl -n nginx-test-vault exec "$POD" -- env | grep '^APP_'

# Parcours A — PostgreSQL : la DSN rendue + la preuve du redémarrage
kubectl -n pg-rotate-demo get secret pg-rotate-creds -o jsonpath='{.data.DATABASE_URL}' | base64 -d; echo
kubectl -n pg-rotate-demo get deploy pg-rotate-demo -o jsonpath='{.metadata.generation}'; echo

# Sur un problème de synchro, la source de vérité reste les logs de l'opérateur :
kubectl -n vault-secrets-operator logs deploy/vault-secrets-operator-controller-manager -f
```

## ⚠️ Pièges

- **`20-dynamic-db.yaml` ne peut pas se synchroniser en l'état.** Il demande `mount: db`, mais
  `../vault/00-secrets-engines.sh:19` monte le moteur `database` sur **`database/`** (pas de
  `-path=db`), et la policy `vso-dynamic-db.hcl` n'autorise que `db/creds/demo-app`. Résultat :
  `403`/`404` systématique. Correction côté Vault (`vault secrets enable -path=db database`) et
  explication complète dans `../vault/LISEZ-MOI.md`. Le moteur `database` a **aussi** besoin d'une
  connexion et d'un role `creds/demo-app` pointant une vraie base — laissés en commentaire dans le
  script.
- **`50-demo-deployment.yaml` ne démarre pas si un des 3 Secret manque.** Aucune référence n'est
  marquée `optional: true` : sans `dynamic-db` (cf. piège précédent) le pod reste en
  `CreateContainerConfigError`, et sans `pki-tls` il reste bloqué en `ContainerCreating` (volume
  introuvable). Le diagnostic est dans `kubectl -n demo describe pod`, pas dans les logs.
- **`02` et `03` sont deux alternatives, pas deux étapes.** Appliquer les deux crée deux `VaultAuth`
  pour le même role — inutile, et source de confusion sur lequel un CR utilise réellement.
- **`SecretSynced: false`** : lire l'event du CR (`kubectl describe`). En pratique soit un login
  refusé (role / SA / namespace / audience — cf. `../vault/LISEZ-MOI.md`), soit un `mount`/`path` faux.
- **Le `Secret` change mais pas le pod** : il manque `rolloutRestartTargets`. Le `Secret` K8s est
  bien à jour (`kubectl get secret` le prouve), mais le process garde l'ancienne valeur en mémoire.
- **`VaultPKISecret` refusé** : `commonName` hors des `allowed_domains` du role PKI, ou `ttl`
  demandé supérieur au `max_ttl` du role (72h ici).
- **`excludes` + `transformationRefs`** : sans `excludes: [".*"]` (ou `excludeRaw: true`), le Secret
  rendu contient **en plus** les clés brutes de Vault (`username`, `password`, `ttl`…). Pratique
  pour déboguer, à éviter quand on veut un Secret propre.

## 📚 Références

- [VSO — API reference (toutes les CRD)](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/api-reference)
- [VSO — `SecretTransformation` / templating](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/secret-transformation)
- [VSO — exemples officiels (dépôt GitHub)](https://github.com/hashicorp/vault-secrets-operator/tree/main/config/samples)
