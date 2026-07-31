<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🐘 `cloudnative-pg/` — PostgreSQL HA déclaratif (opérateur CloudNativePG)

> **Un CRD `Cluster` = un PostgreSQL HA complet.** L'opérateur observe cet objet et réconcilie
> l'état réel : il crée les pods, monte les PVC, élit un primaire, attache les réplicas en
> streaming, et **bascule tout seul** si le primaire tombe. Le cas d'école du pattern *operator*.

## 🎯 À quoi ça sert

- Démontrer le **pattern operator** : on décrit l'état voulu, le contrôleur fait le reste
  (provisioning, réplication, **failover automatique**, rolling updates, backups).
- Montrer un **failover en direct** — 30 s de démo (cf. 🧪 Scénarios).
- Fournir une **vraie base** aux autres addons : identifiants rotés par Vault
  (`../vault-secret-operator/`), sauvegardes S3 vers MinIO (`../minio-s3/cluster/`).

Ce qui est déployé : l'opérateur (1 pod, ns `cnpg-system`) + un cluster de démo `pg-demo`
(ns `cnpg-demo`, 3 instances = 1 primaire + 2 réplicas, PVC 1Gi RWO sur `longhorn-r1`).

### Deux couches de résilience (à bien distinguer en formation)

1. **Réplication PostgreSQL** (logique) : le primaire streame ses WAL vers 2 réplicas →
   bascule applicative en cas de perte du primaire.
2. **Réplication Longhorn** (bloc) : un PVC peut être répliqué par Longhorn sur plusieurs
   nodes → survie à la perte d'un disque.

Ce sont **deux mécanismes indépendants**. **Choix de ce lab : 1 réplica Longhorn** pour les PVC
de la base (StorageClass dédiée `longhorn-r1`), car PostgreSQL réplique déjà au niveau
applicatif — empiler 3 réplicas bloc × 3 instances = 9 copies du même jeu de données, ce qui
sature le disque OS partagé (~20 Go). Si un node meurt, **CNPG reconstruit** l'instance perdue
depuis le primaire. C'est le pattern recommandé pour un opérateur de BDD sur Longhorn, et un
bon support pour expliquer « réplication applicative vs réplication stockage » — et *quand ne
pas doubler*.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| **Longhorn** (`../longhorn/`) | fournit le CSI qui provisionne les PVC | `kubectl -n longhorn-system get pods` |
| StorageClass **`longhorn-r1`** (`../longhorn/longhorn-r1-storageclass.yaml`) | stockage des 3 instances ; le script **s'arrête** (`exit 1`) si elle manque | `kubectl get sc longhorn-r1` |
| **3 workers** | l'anti-affinité par défaut place 1 instance par worker | `kubectl get nodes` |

> ℹ️ **`longhorn-r1` n'est pas créée par cet addon.** `cluster-demo.yaml` ne fait que la
> **référencer** ; elle est définie dans `_k8s/longhorn/longhorn-r1-storageclass.yaml`.
> Avec moins de 3 workers, réduire `instances` dans `cluster-demo.yaml` (sinon un pod reste
> `Pending`).

## ⚡ Installation

```bash
kubectl apply -f _k8s/longhorn/longhorn-r1-storageclass.yaml   # si pas déjà fait
./_k8s/cloudnative-pg/cloudnative-pg-up.sh
```

Version épinglée dans le script : chart **`cnpg/cloudnative-pg` 0.29.0** (app **v1.30.0**),
surchargeable par `CNPG_VERSION=…`. Idempotent (`helm upgrade --install` + `kubectl apply`).

## 🔧 Ce que fait le script

1. vérifie `kubectl`/`helm`, l'apiserver, et la présence de la SC `longhorn-r1` ;
2. installe l'**opérateur** dans `cnpg-system` avec `values.yaml`, puis attend le rollout ;
3. applique `cluster-demo.yaml` (namespace `cnpg-demo` + `Cluster` `pg-demo`) et attend
   `condition=Ready` (300 s max, sans échouer si le délai est dépassé).

### Fichiers

| Fichier | Rôle |
|---------|------|
| `values.yaml` | Valeurs Helm de l'opérateur (1 replica, `podMonitorEnabled: false`) |
| `cluster-demo.yaml` | Namespace `cnpg-demo` + `Cluster` `pg-demo` (3 instances, 1Gi RWO sur `longhorn-r1`, `max_connections=100`, `shared_buffers=128MB`) |
| `cloudnative-pg-up.sh` | Installe l'opérateur + applique le cluster de démo |
| `pg-backup-vault-s3.yaml` / `pg-backup-up.sh` | Backup **logique** horaire (`pg_dump`) vers MinIO, avec les creds Vault |
| `pg-app-backup-cnpg.yaml` / `pg-app-backup-cnpg-up.sh` | Backup **natif CNPG** (physique + WAL, PITR) vers MinIO |

### Ce que l'opérateur crée pour toi

| Ressource | Rôle |
|-----------|------|
| `Secret pg-demo-app` | Identifiants applicatifs (`user`, `password`, `dbname`, `host`, `uri`) |
| `Service pg-demo-rw` | Lecture/écriture → **toujours le primaire** |
| `Service pg-demo-ro` | Lecture seule → **réplicas** (répartition de charge lecture) |
| `Service pg-demo-r`  | Tous les nœuds (primaire + réplicas) |
| `Secret pg-demo-superuser` | **Seulement si `enableSuperuserAccess: true`** — absent par défaut (cf. ⚠️ Pièges) |

## ✅ Vérifier

```bash
kubectl -n cnpg-demo get cluster pg-demo                       # READY 3/3, "Cluster in healthy state"
kubectl -n cnpg-demo get pods -l cnpg.io/cluster=pg-demo       # pg-demo-1/2/3 Running, 1 par worker
kubectl -n cnpg-demo get pvc                                   # 3 PVC Bound, 1Gi longhorn-r1

# Se connecter et lire (via le pod primaire)
kubectl -n cnpg-demo exec -it pg-demo-1 -- psql -c '\l'        # liste les bases (dont `app`)
```

Le plugin `kubectl-cnpg` donne une vue riche (à installer côté hôte, optionnel) :

```bash
kubectl cnpg status pg-demo -n cnpg-demo
```

## 🧪 Scénarios

### 1. Failover automatique (le clou du spectacle)

```bash
kubectl -n cnpg-demo get cluster pg-demo -o jsonpath='{.status.currentPrimary}'; echo  # ex: pg-demo-1
kubectl -n cnpg-demo delete pod pg-demo-1                       # on tue le primaire
watch kubectl -n cnpg-demo get cluster pg-demo                  # un réplica est promu en quelques s
```

L'opérateur promeut un réplica, recrée l'ancien primaire en réplica, sans intervention.

### 2. Persistance sur Longhorn

Écris des données, supprime un pod : le PVC est réattaché, les données survivent. Supprime le
node (VM) : CNPG reconstruit l'instance depuis le primaire (avec `longhorn-r1`, le bloc n'est
**pas** répliqué ailleurs — c'est PostgreSQL qui rattrape, cf. les deux couches plus haut).

### 3. Consommer la base depuis une app

Le `Secret pg-demo-app` contient une `uri` prête à l'emploi. Idéal pour brancher une appli de
démo, ou coupler avec **Vault**/VSO pour des identifiants rotés (cf. `../vault-secret-operator/`).

```bash
kubectl -n cnpg-demo get secret pg-demo-app -o jsonpath='{.data.uri}' | base64 -d; echo
```

### 4. Scale des réplicas

```bash
kubectl -n cnpg-demo patch cluster pg-demo --type merge -p '{"spec":{"instances":2}}'  # 3→2
# (repasser à 3 ensuite ; observer le rebalancing)
```

## 💽 Sauvegardes — deux mécanismes qui coexistent

Les deux poussent vers **MinIO** et exigent donc l'addon **`../minio-s3/cluster/`** (namespace
`minio-cluster`, Secret `minio-creds` : les deux scripts lisent le mot de passe root MinIO et
créent bucket + utilisateur dédié via un `port-forward`).

| | `pg_dump`-via-Vault (`pg-backup-vault-s3.yaml`) | **Natif CNPG** (`pg-app-backup-cnpg.yaml`) |
|---|---|---|
| Passe par les CRD CNPG | ❌ non (CronJob standard) | ✅ oui (`Backup` / `ScheduledBackup`) |
| Type | Logique (`pg_dump \| gzip`) | **Physique** (base backup + archivage WAL) |
| Portée | 1 base (`vault`) | Toute l'instance `pg-demo` (dont `app`) |
| Identifiants PG | **Vault** (`pg-rotate-creds`, rotés) | Internes CNPG |
| Fréquence | CronJob `0 * * * *` (horaire) | `ScheduledBackup` `0 0 * * * *` (horaire) + WAL en continu |
| PITR (restauration à T) | ❌ non | ✅ oui |
| Bucket / rétention | `pg-backups` — **aucune expiration** | `cnpg-backups` — `retentionPolicy: 7d` |

### A. Backup logique horaire via les identifiants Vault

Sauvegarde `pg_dump` de la base `vault`, toutes les heures, poussée dans le bucket
`pg-backups` — en se connectant à PostgreSQL avec les identifiants **rotés par Vault**.

```
CronJob pg-backup-vault-s3 (ns pg-rotate-demo, schedule "0 * * * *")
   │  pg_dump "$DATABASE_URL"  (creds Vault du Secret pg-rotate-creds, sslmode=require)
   ▼  vault-<timestamp>.sql.gz
   └─ mc cp ──► bucket MinIO pg-backups   (utilisateur MinIO dédié pg-backup, scopé au bucket)
```

Prérequis en plus de MinIO : la **rotation Vault en place** (Secret `pg-rotate-creds` dans
`pg-rotate-demo` — le script refuse de continuer sans lui) et le cluster `pg-demo` UP.

```bash
./_k8s/cloudnative-pg/pg-backup-up.sh     # bucket + user MinIO + Secret minio-backup-creds + CronJob
# Déclencher un backup immédiat pour vérifier :
kubectl -n pg-rotate-demo create job pg-backup-now --from=cronjob/pg-backup-vault-s3
kubectl -n pg-rotate-demo logs job/pg-backup-now
```

> ⚠️ **Ce backup NE passe PAS par les CRD de CloudNativePG.** Ni `Backup`/`ScheduledBackup`,
> ni `barmanObjectStore` : c'est un `pg_dump` porté par un CronJob standard, choisi **exprès**
> pour utiliser les creds Vault — ce que le backup natif CNPG ne sait pas faire.

### B. Backup natif CloudNativePG (CRD → MinIO, avec PITR)

Backup **physique** de toute l'instance `pg-demo` (base `app` incluse) + **archivage WAL
continu**, poussé par barman-cloud. Permet la **restauration à un instant T**.

```
Cluster pg-demo  ── spec.backup.barmanObjectStore ──►  bucket MinIO cnpg-backups/pg-demo/
   ├─ base/<timestamp>/data.tar.gz   (base backup, déclenché par Backup/ScheduledBackup)
   └─ wals/.../*.gz                  (archivage WAL CONTINU => PITR)
ScheduledBackup pg-demo-hourly  ── "0 0 * * * *" (cron 6 champs : sec min h …) ──► base backups
```

```bash
# bucket/user MinIO dédiés + Secret cnpg-backup-s3 + patch barmanObjectStore
# (+ retentionPolicy 7d) + ScheduledBackup + 1 backup immédiat
./_k8s/cloudnative-pg/pg-app-backup-cnpg-up.sh

# Vérifier
kubectl -n cnpg-demo get backups                       # phase=completed, method=barmanObjectStore
kubectl -n cnpg-demo get cluster pg-demo \
  -o jsonpath='{.status.firstRecoverabilityPoint}{"\n"}'   # point de départ PITR (non vide)
mc ls -r <alias>/cnpg-backups/pg-demo/                 # base/… + wals/…
```

> 💡 **Restauration (PITR)** : on crée un **nouveau** `Cluster` avec `spec.bootstrap.recovery`
> pointant sur le même `barmanObjectStore` (+ `recoveryTarget` pour un instant T). On ne
> restaure pas « dans » le cluster existant. Voir la doc CNPG « Recovery ».

## 🚑 Dépannage

- **Cluster bloqué en `Creating a new replica`** → provisioning normal (bootstrap + join) ;
  compter 2-5 min. Sinon vérifier les PVC (`kubectl -n cnpg-demo get pvc`) et Longhorn.
- **Un réplica reste `Pending`** → l'anti-affinité veut 1 instance/worker : pas assez de
  workers. Réduire `instances` ou ajouter un worker (`WORKERS` de `lab.env`).
- **PVC `Pending`** → StorageClass `longhorn-r1` absente ou Longhorn KO (voir `../longhorn/`).
- **Volumes `Degraded` côté Longhorn** → `defaultReplicaCount` Longhorn > nombre de workers.
- **`pg-backup-up.sh` : « secret pg-rotate-creds absent »** → la rotation Vault n'est pas en
  place : dérouler `../vault-secret-operator/` (section rotation) d'abord.
- **Backup CNPG qui reste `running`/`failed`** → vérifier la condition d'archivage :
  `kubectl -n cnpg-demo get cluster pg-demo -o jsonpath='{.status.conditions}'`
  (`ContinuousArchiving` doit être `True`), puis les logs du sidecar de l'instance primaire.

## ⚠️ Pièges

- **Longhorn `faulted` / `ReplicaSchedulingFailure: insufficient storage`** — *déjà rencontré
  sur ce lab* : avec `default-replica-count=3` et le disque OS partagé (~20 Go), 3 réplicas
  bloc × 3 instances ne rentrent pas. D'où `longhorn-r1`. Diagnostic :
  `kubectl -n longhorn-system get volume <pvc> -o jsonpath='{.status.conditions}'`.
- **Pas de Secret `pg-demo-superuser` par défaut.** Depuis CNPG 1.21,
  `enableSuperuserAccess` vaut **`false`** et `cluster-demo.yaml` ne le repositionne pas : le
  Secret n'existe donc **pas**. Or `../vault-secret-operator/vault/pg-dynamic-rotate.sh` le lit
  pour configurer le moteur `database/` de Vault → il **échoue au premier lancement**. À faire
  avant :
  ```bash
  kubectl -n cnpg-demo patch cluster pg-demo --type=merge \
    -p '{"spec":{"enableSuperuserAccess":true}}'
  ```
- **Le bucket `pg-backups` n'a AUCUNE règle d'expiration.** Le CronJob est horaire → **~8 760
  objets par an**, sur un bucket MinIO posé sur `local-path` (4 × 10Gi, EC:2) et sans quota.
  Rien ne purge, ni le script ni le manifeste. En lab : surveiller, ou poser une règle de cycle
  de vie à la main côté MinIO (`mc ilm rule add`, cf. doc MinIO). Le backup **natif**,
  lui, est borné (`retentionPolicy: "7d"` posé par `pg-app-backup-cnpg-up.sh`).
- **Le CronJob télécharge `mc` depuis Internet à CHAQUE exécution.**
  `pg-backup-vault-s3.yaml` fait `wget https://dl.min.io/…/mc` dans le conteneur, **sans
  version épinglée ni vérification de checksum** : sans accès sortant (ou si `dl.min.io`
  bouge), le backup horaire échoue. Le sauvetage dépend donc d'Internet — acceptable en lab,
  à remplacer par une image contenant `mc` en vrai.
- **`barmanObjectStore` in-tree est déprécié.** Sur CNPG **1.30** il fonctionne mais son
  retrait est annoncé en **1.31.0**. Migration : le **Barman Cloud Plugin** (CNPG-I, objet
  `ObjectStore` + `plugin` sur le `Cluster`). Le principe (base + WAL → S3/MinIO, PITR) est
  identique ; seule la déclaration change.
- **Métriques absentes de Prometheus** : c'est normal, tout est coupé par défaut. Après
  l'install de `../observability/`, passer `monitoring.enablePodMonitor: true` dans
  `cluster-demo.yaml` (métriques des instances) **et** `monitoring.podMonitorEnabled: true`
  dans `values.yaml` (métriques de l'opérateur), puis relancer le script. Le CRD `PodMonitor`
  n'existe qu'après kube-prometheus-stack — d'où l'ordre.

## 📚 Références

- [CloudNativePG — Documentation](https://cloudnative-pg.io/documentation/current/)
- [CloudNativePG — Cluster (API)](https://cloudnative-pg.io/documentation/current/cloudnative-pg.v1/)
- [CloudNativePG — Backup sur objet S3](https://cloudnative-pg.io/documentation/current/backup/)
- [CloudNativePG — Barman Cloud Plugin (successeur de l'in-tree)](https://github.com/cloudnative-pg/plugin-barman-cloud)
- Addons liés : `../longhorn/` (SC `longhorn-r1`) · `../minio-s3/cluster/` (cible des backups) ·
  `../vault-secret-operator/` (rotation des identifiants) · `../observability/` (métriques)
