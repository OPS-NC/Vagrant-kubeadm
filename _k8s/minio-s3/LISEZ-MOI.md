<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🪣 `minio-s3/` — MinIO standalone (S3 + console d'admin) sur local-path

> Un endpoint **compatible S3** dans le cluster, en **un seul pod**, avec une **console
> d'administration complète** (fork Pigsty). C'est la version simple : un PVC `local-path`,
> aucune résilience. La version résiliente est dans **[`cluster/`](./cluster/)**.

## 🎯 À quoi ça sert

Avoir un S3 local pour tester des backups, des SDK, `mc`, des politiques de buckets — sans
compte cloud. Deux hostnames exposés en HTTPS via `main-gateway` (wildcard `*.kubeadm.lab.example.io`) :

| Service | URL | Port conteneur |
|---|---|---|
| **API S3** | `https://minio.kubeadm.lab.example.io` | 9000 |
| **Console admin** | `https://minio-console.kubeadm.lab.example.io` | 9001 |

En interne au cluster : `http://minio.minio-s3.svc.cluster.local:9000`.

### Standalone (ici) ou distribué ([`cluster/`](./cluster/)) ?

| | **Standalone (ici)** | **Cluster** (`cluster/`) |
|---|---|---|
| Workload | Deployment, 1 replica | StatefulSet, **4 pods** (`podManagementPolicy: Parallel`) |
| Drives | 1 PVC `local-path` 10 Gi | **4** PVC `local-path` 10 Gi (1/pod, 1/worker) |
| Erasure coding | ❌ aucun | ✅ **EC:2** |
| Résilience | nulle : le node meurt ⇒ données perdues | tolère ~2 nœuds/drives down |
| Workers requis | 1 | **4** (anti-affinité stricte) |
| Namespace | `minio-s3` | `minio-cluster` (les deux coexistent) |
| Hostnames | `minio` / `minio-console` | `minio-cluster` / `minio-cluster-console` |

> ℹ️ **Les backups du lab ne visent plus ce standalone.** Depuis le passage au cluster MinIO,
> `../cloudnative-pg/pg-backup-up.sh` et `pg-app-backup-cnpg-up.sh` pointent
> `http://minio.minio-cluster.svc.cluster.local:9000`. Ce dossier reste le bac à sable simple
> (et la brique pédagogique « avant/après erasure coding »).

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| StorageClass **`local-path`** (`../local-path-storage/`) | le PVC 10 Gi de `/data` ; `minio-up.sh` s'arrête sans elle | `kubectl get storageclass local-path` |
| `main-gateway` + écouteur `https` (`../envoy-gateway/`) | porte les deux `HTTPRoute` | `kubectl get gateway -n envoy-gateway-system` |
| Cert wildcard `*.kubeadm.lab.example.io` (`../cert-manager/`) | TLS des deux hostnames | `kubectl -n envoy-gateway-system get certificate` |
| DNS `minio` + `minio-console` → `192.168.56.200` | atteindre le VIP Envoy | `getent hosts minio.kubeadm.lab.example.io` |
| `openssl` sur l'hôte | génère le mot de passe root par défaut | `openssl version` |

## ⚡ Installation

```bash
./_k8s/minio-s3/minio-up.sh
# Identifiants réglables : MINIO_ROOT_USER (défaut « admin ») / MINIO_ROOT_PASSWORD (généré)
MINIO_ROOT_PASSWORD='MonPassLab' ./_k8s/minio-s3/minio-up.sh
```

Image épinglée dans `minio-s3.yaml` : **`docker.io/pgsty/minio:RELEASE.2026-06-18T00-00-00Z`**.

## 🔧 Ce que fait le script

1. Vérifie `kubectl`, l'apiserver et la présence de la StorageClass `local-path`.
2. Crée le namespace `minio-s3` et le Secret `minio-creds` (`root-user` / `root-password`) —
   **jamais écrasé** s'il existe : relancer le script ne change pas le mot de passe.
3. Applique `minio-s3.yaml` : PVC 10 Gi, Deployment (`strategy: Recreate`, car le volume RWO
   n'accepte pas deux pods), Service ClusterIP, deux `HTTPRoute`.
4. Attend le `rollout` (180 s) puis affiche les URL **et les identifiants root en clair sur
   stdout** (cf. Pièges).

### Pourquoi le fork Pigsty (`pgsty/minio`)

Ni l'image « officielle », ni Bitnami :

- **Bitnami** (`bitnami/minio`) s'appuie depuis **août 2025** sur des images **gelées**
  (`bitnamilegacy/*`, plus mises à jour).
- **Upstream `minio/minio`** a **amputé la console communautaire** vers
  `RELEASE.2025-05-24` (il ne reste qu'un navigateur d'objets : plus de gestion users /
  buckets / policies / lifecycle depuis le web), puis le dépôt a été **archivé
  « no longer maintained »** (fév. 2026).
- **Pigsty** rebuild le serveur MinIO **et restaure la console d'admin complète** → image
  **récente** ET **administrable**. C'est le fork le plus actif (billet « MinIO is Dead, Long
  Live MinIO »).

Alternatives possibles : upstream épinglé `RELEASE.2025-04-22T22-12-26Z` (dernière release avec
la console admin officielle, mais figé), autres forks de console (`huncrys/minio-console`,
`georgmangold/console`), édition payante **AIStor**, ou simplement le CLI **`mc`**.

## ✅ Vérifier

```bash
kubectl -n minio-s3 get pods,pvc,svc,httproute
curl -sk -o /dev/null -w '%{http_code}\n' --resolve minio.kubeadm.lab.example.io:443:192.168.56.200 \
  https://minio.kubeadm.lab.example.io/minio/health/ready      # 200
```

## 🌐 Accès

| Quoi | Comment |
|---|---|
| Console admin | `https://minio-console.kubeadm.lab.example.io` |
| API S3 | `https://minio.kubeadm.lab.example.io` (path-style, `region` quelconque : `us-east-1`) |
| Utilisateur root | `kubectl -n minio-s3 get secret minio-creds -o jsonpath='{.data.root-user}' \| base64 -d; echo` |
| Mot de passe root | `kubectl -n minio-s3 get secret minio-creds -o jsonpath='{.data.root-password}' \| base64 -d; echo` |

Le cert wildcard est émis par Let's Encrypt **staging** → avertissement TLS à accepter dans le
navigateur, et `--insecure` pour `mc` (cf. `../cert-manager/`).

```bash
mc alias set lab https://minio.kubeadm.lab.example.io <user> <pass> --insecure
mc mb lab/mon-bucket --insecure                       # créer un bucket
mc admin user add lab bob <mot-de-passe> --insecure   # gérer les users
mc ls lab --insecure
```

## ⚠️ Pièges

- **`minio-up.sh` affiche l'utilisateur ET le mot de passe root en clair sur stdout** (fin de
  run). Ça finit dans l'historique du terminal, les logs de CI, une capture d'écran… Préférer
  les relire depuis le Secret (tableau ci-dessus) et penser à nettoyer la sortie si tu la
  partages.
- **Aucune résilience.** Deployment 1 replica + 1 PVC `local-path` = stockage **node-local**.
  Si le worker qui héberge le PV meurt, les objets sont perdus. Pour de la vraie résilience
  objet, utiliser **[`cluster/`](./cluster/)** (4 drives, EC:2, sur local-path lui aussi — pas
  besoin de Longhorn : MinIO se réplique tout seul).
- **Les 10 Gi du PVC ne sont pas une limite.** `local-path` provisionne un dossier hostPath :
  rien n'empêche MinIO de remplir la partition `/var` du worker. L'`ephemeral-storage`
  allocatable mesuré sur ce lab est de **~16,9 Go/node** (disque de 20 Go partagé avec l'OS et
  les images conteneurs) → remplir un bucket déclenche du `DiskPressure` et l'**éviction** de
  pods sur ce node. Surveiller `kubectl describe node <worker> | grep -i pressure`.
- **Le Secret `minio-creds` n'est pas dans git** (créé par le script). Le perdre = perdre
  l'accès root : `kubectl -n minio-s3 delete secret minio-creds` puis relancer le script
  régénère un mot de passe, mais MinIO garde l'ancien tant que le pod n'est pas recréé.
- **Console derrière un hostname distinct** : `MINIO_BROWSER_REDIRECT_URL` porte
  `https://minio-console.kubeadm.lab.example.io` dans `minio-s3.yaml` — domaine **neutre** du dépôt
  public. `minio-up.sh` la substitue avec les hostnames des `HTTPRoute` depuis `LAB_DOMAIN`
  (`lab.env`). Un `kubectl apply -f minio-s3.yaml` **direct** garde le domaine d'exemple et casse
  les redirections de login. Cf. [`../LISEZ-MOI.md`](../LISEZ-MOI.md#-lab_domain--le-domaine-des-ui).

## 📚 Références

- MinIO retire l'admin de la console communautaire :
  <https://blocksandfiles.com/2025/06/19/minio-removes-management-features-from-basic-community-edition-object-storage-code/>
- Discussion officielle : <https://github.com/minio/minio/discussions/21326>
- Images du fork : <https://hub.docker.com/r/pgsty/minio/tags>
- [`cluster/`](./cluster/) — la variante distribuée 4 nœuds (erasure coding).
