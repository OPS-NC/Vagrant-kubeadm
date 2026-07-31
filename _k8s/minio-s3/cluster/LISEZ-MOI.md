<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🧺 `minio-s3/cluster/` — MinIO distribué 4 nœuds (erasure coding) sur local-path

> Variante **résiliente** du MinIO standalone (`../`) : un **StatefulSet de 4 pods**, 1 drive
> (PVC `local-path`) par pod, 1 pod par worker. MinIO **erasure-code** les objets sur les 4
> drives → le stockage objet survit à la perte de nœuds **sans Longhorn**, exactement comme
> CloudNativePG assure lui-même la réplication de Postgres.

> ⚠️ **Prérequis BLOQUANT : 4 workers `Ready`.** Le défaut du dépôt (`lab.env.example`) est
> `WORKERS=3` → avec cette topologie l'addon **ne peut pas démarrer du tout**. Voir Prérequis.

## 🎯 À quoi ça sert

C'est le S3 « pour de vrai » du lab : la cible des sauvegardes PostgreSQL
(`../../cloudnative-pg/pg-backup-up.sh` et `pg-app-backup-cnpg-up.sh` pointent
`http://minio.minio-cluster.svc.cluster.local:9000`), et la démo pédagogique de l'erasure
coding face au standalone.

| | Standalone (`../`) | **Cluster (ici)** |
|---|---|---|
| Workload | Deployment 1 replica | **StatefulSet 4 pods** |
| Drives | 1 (local-path 10 Gi) | **4** (1 PVC 10 Gi/pod, 1/worker) |
| Erasure coding | ❌ | ✅ **EC:2** (2 parités) |
| Résilience | aucune (perte du node = perte data) | **tolère ~2 nœuds/drives down** |
| Workers requis | 1 | **4** |
| Namespace | `minio-s3` | `minio-cluster` (coexistent) |

Exposition (HTTPS via `main-gateway`, wildcard `*.kubeadm.lab.example.io`) :

| Service | URL | Port |
|---|---|---|
| **API S3** | `https://minio-cluster.kubeadm.lab.example.io` | 9000 |
| **Console admin** | `https://minio-cluster-console.kubeadm.lab.example.io` | 9001 |

En interne : `http://minio.minio-cluster.svc.cluster.local:9000`.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| **≥ 4 workers `Ready`** | `replicas: 4` + anti-affinité **`requiredDuringScheduling`** sur `kubernetes.io/hostname` (1 pod max par node) ; les control planes sont taintés `NoSchedule` donc **ne comptent pas** | `kubectl get nodes -l '!node-role.kubernetes.io/control-plane'` |
| StorageClass **`local-path`** (`../../local-path-storage/`) | les 4 PVC du `volumeClaimTemplates` ; le script s'arrête sans elle | `kubectl get storageclass local-path` |
| `main-gateway` + écouteur `https` + cert wildcard | les deux `HTTPRoute` | `kubectl get gateway -n envoy-gateway-system` |
| DNS `minio-cluster` + `minio-cluster-console` → `192.168.56.200` | atteindre le VIP Envoy | `getent hosts minio-cluster.kubeadm.lab.example.io` |

> ⚠️ **Passer `WORKERS=4` (ou plus) dans `lab.env` avant de monter le cluster.**
> `lab.env.example` livre `WORKERS=3`, et `minio-cluster-up.sh` ne fait qu'**avertir** (un
> simple `echo`, pas un `exit`) s'il y a moins de 4 workers. Il applique quand même le
> manifeste : le 4ᵉ pod reste **`Pending` pour toujours** (anti-affinité stricte, plus aucun node
> éligible), donc le `rollout status --timeout=300s` **échoue au bout de 5 minutes** et le
> déploiement démarre au mieux **dégradé dès le premier jour** (3 drives sur 4, zéro marge : une
> panne de plus et l'erasure set perd son quorum d'écriture). Changer `WORKERS` demande un
> `vagrant destroy` + remontée du cluster (cf. `CLAUDE.md`) : décide **avant**.

## ⚡ Installation

```bash
./_k8s/minio-s3/cluster/minio-cluster-up.sh
# Identifiants réglables : MINIO_ROOT_USER (défaut « admin ») / MINIO_ROOT_PASSWORD (généré)
```

Image épinglée dans `minio-cluster.yaml` :
**`docker.io/pgsty/minio:RELEASE.2026-06-18T00-00-00Z`** (fork Pigsty — récent + console
d'admin, cf. `../LISEZ-MOI.md`).

## 🔧 Ce que fait le script

1. Vérifie `kubectl`, l'apiserver, la StorageClass `local-path`, puis **compte les workers
   `Ready`** et avertit s'il y en a moins de 4 (sans bloquer).
2. Crée le namespace `minio-cluster` et le Secret `minio-creds` — **non écrasé** s'il existe.
3. Applique `minio-cluster.yaml` (Service headless, StatefulSet, Service ClusterIP, 2 `HTTPRoute`).
4. Attend `rollout status statefulset/minio --timeout=300s`, puis affiche les URL **et les
   identifiants root en clair** (cf. Pièges).

### Pourquoi 4 nœuds (et pas 3)

MinIO exige un **minimum de 4 drives** par *erasure set*, répartis **uniformément** entre les
nœuds. Avec **1 drive par pod** (le pattern K8s propre sur local-path) :

- **3 nœuds × 1 drive = 3 drives** → sous le minimum **et** non uniforme → refusé.
- **4 nœuds × 1 drive = 4 drives** → 1 erasure set de 4, **EC:2** → le minimum naturel.
- 3 nœuds ne redevient possible qu'avec **≥ 2 drives/nœud** (3 × 2 = 6 drives = 1 set de 6),
  c.-à-d. 2 PVC par pod : plus complexe, non retenu ici.

> ℹ️ EC:2 sur 4 drives = 2 données + 2 parités. On peut **perdre jusqu'à 2 drives/nœuds** en
> conservant la **lecture** ; l'écriture demande un quorum (≥ moitié + 1 des drives).

### Topologie déployée

```
StatefulSet minio (podManagementPolicy: Parallel — les 4 pods démarrent ENSEMBLE et s'attendent)
  minio-0 @ worker A ─ PVC data-minio-0 (local-path 10Gi)  ┐
  minio-1 @ worker B ─ PVC data-minio-1                    ├─ 1 pool, 1 erasure set de 4, EC:2
  minio-2 @ worker C ─ PVC data-minio-2                    │
  minio-3 @ worker D ─ PVC data-minio-3                    ┘
  ▲ découverte des pairs via le Service HEADLESS minio-hl :
     server http://minio-{0...3}.minio-hl.minio-cluster.svc.cluster.local:9000/data
Service minio (ClusterIP) ── équilibre sur les 4 pods ── HTTPRoutes (API + console)
```

Points clés du manifeste :

- **`podManagementPolicy: Parallel`** (obligatoire) : en `OrderedReady`, `minio-0` ne serait
  jamais « ready » sans ses pairs → interblocage. En parallèle, les 4 bootent et forment le quorum.
- **Service headless `minio-hl`** (`clusterIP: None`, `publishNotReadyAddresses: true`) : DNS
  stable par pod, résolu **avant** que les pods soient ready.
- **anti-affinité `hostname` (`required…`)** : 1 pod/worker → erasure réparti sur 4 nœuds distincts.
- **`startupProbe` `failureThreshold: 30` × 5 s** : jusqu'à 150 s pour former le quorum au boot.

## ✅ Vérifier

```bash
kubectl -n minio-cluster get pods -o wide            # minio-0..3, 1/1, sur 4 workers distincts
mc alias set clu https://minio-cluster.kubeadm.lab.example.io <user> <pass> --insecure
mc admin info clu                                    # « 4 drives online, 0 offline », EC:2
```

## 🌐 Accès

| Quoi | Comment |
|---|---|
| Console admin | `https://minio-cluster-console.kubeadm.lab.example.io` |
| API S3 | `https://minio-cluster.kubeadm.lab.example.io` (path-style) |
| Utilisateur root | `kubectl -n minio-cluster get secret minio-creds -o jsonpath='{.data.root-user}' \| base64 -d; echo` |
| Mot de passe root | `kubectl -n minio-cluster get secret minio-creds -o jsonpath='{.data.root-password}' \| base64 -d; echo` |

Cert Let's Encrypt **staging** → `--insecure` pour `mc`, avertissement à accepter au navigateur.

## 🧪 Scénarios

**Tester la résilience** — supprimer un pod : le cluster reste lisible/écrivable.

```bash
kubectl -n minio-cluster delete pod minio-2
mc admin info clu       # 3/4 online, toujours opérationnel ; le pod revient et se resynchronise
```

**Migrer depuis le standalone** — les deux MinIO coexistent (namespaces et hostnames distincts) :

```bash
mc alias set std https://minio.kubeadm.lab.example.io <user> <pass> --insecure
mc alias set clu https://minio-cluster.kubeadm.lab.example.io <user> <pass> --insecure
mc mb clu/pg-backups clu/cnpg-backups
mc mirror --preserve std/pg-backups clu/pg-backups
mc mirror --preserve std/cnpg-backups clu/cnpg-backups
```

Puis repointer les jobs de backup (`MINIO_ENDPOINT` / `endpointURL`) vers
`http://minio.minio-cluster.svc.cluster.local:9000` — c'est déjà le cas des scripts de
`../../cloudnative-pg/` — et décommissionner le standalone.

## ⚠️ Pièges

- **Moins de 4 workers = installation qui ne converge jamais** : le 4ᵉ pod reste `Pending`
  (anti-affinité `required…`), `rollout status` échoue après 5 min, et l'erasure set tourne
  d'emblée à 3/4 drives. Le script n'échoue **pas** à ce stade (simple `echo` d'avertissement,
  `minio-cluster-up.sh`) : ne pas conclure de son démarrage silencieux que la topologie est bonne.
- **`minio-cluster-up.sh` affiche l'utilisateur et le mot de passe root en clair sur stdout.**
  Les relire plutôt depuis le Secret (tableau Accès).
- **Les 4 × 10 Gi ne sont pas des quotas.** `local-path` = dossier hostPath, la taille du PVC
  n'est **jamais** appliquée. L'`ephemeral-storage` allocatable mesuré ici est de **~16,9 Go par
  node** (disque de 20 Go partagé avec l'OS et les images) : remplir les buckets provoque du
  `DiskPressure` et l'**éviction de pods** sur les workers concernés — donc potentiellement la
  perte simultanée de plusieurs drives MinIO. Surveiller :
  ```bash
  kubectl get nodes -o custom-columns=NAME:.metadata.name,EPH:.status.allocatable.ephemeral-storage
  kubectl describe node <worker> | grep -i pressure
  ```
- **Drives node-local** : perdre un worker = perdre un drive. EC:2 encaisse 2 pertes, pas plus ;
  un `vagrant destroy` en encaisse 4 (et les données avec).
- **Scaling** : MinIO grossit par **ajout de server pools** (≥ 4 drives par pool), jamais par
  ajout d'un drive isolé. Pour agrandir, déclarer un 2ᵉ pool dans les args
  (`… /data http://minio2-{0...3}…/data`).
- **Perf** : 1 drive/pod sur un disque node-local partagé avec l'OS — suffisant pour un lab,
  pas pour de la charge réelle.
- **Console derrière un hostname distinct** : `MINIO_BROWSER_REDIRECT_URL` porte
  `https://minio-cluster-console.kubeadm.lab.example.io` dans le manifeste — domaine **neutre** du
  dépôt public, substitué par `minio-cluster-up.sh` depuis `LAB_DOMAIN` (`lab.env`) en même temps
  que les hostnames des `HTTPRoute`. Un `kubectl apply` direct garde le domaine d'exemple et
  casse les redirections de login. Cf. [`../../LISEZ-MOI.md`](../../LISEZ-MOI.md#-lab_domain--le-domaine-des-ui).

## 📚 Références

- `../LISEZ-MOI.md` — MinIO standalone, et le détail du **pourquoi le fork `pgsty/minio`**.
- `../../local-path-storage/` — la StorageClass consommée par les 4 drives.
- `../../cloudnative-pg/` — les sauvegardes PostgreSQL qui visent ce cluster.
- [Documentation MinIO (Kubernetes)](https://min.io/docs/minio/kubernetes/upstream/) — déploiement
  distribué, erasure coding et quorum.
