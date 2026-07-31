<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🐮 `longhorn/` — stockage bloc répliqué (Longhorn 1.12) sur kubeadm/Debian

> Fournit des `PersistentVolume` **répliqués entre workers** (StorageClass `longhorn`) à partir
> du disque des nodes, sans matériel ni cloud provider. C'est le seul stockage **HA** du lab :
> un volume survit à la perte d'un node, contrairement à `../local-path-storage/`.

## 🎯 À quoi ça sert

Poser deux StorageClass et le CSI qui va avec :

| StorageClass | Réplicas bloc | Par défaut | Pour qui |
|---|---|---|---|
| `longhorn` | un par worker, plafonné à 3 | oui (`values.yaml`) | données à protéger : `../wordpress-example/`, `../vault-cluster/` |
| `longhorn-r1` | 1 | non | `../cloudnative-pg/` et `../observability/` (réplication applicative ou donnée reconstructible) |

Fichiers du dossier :

| Fichier | Rôle |
|---|---|
| `longhorn-up.sh` | **l'install** : namespace, chart + les deux StorageClass + `HTTPRoute` |
| `values.yaml` | Valeurs Helm : `defaultDataPath`, `defaultReplicaCount`, `persistence.defaultClass: true` |
| `longhorn-r1-storageclass.yaml` | StorageClass socle `longhorn-r1` (1 réplica bloc) |
| `httproute.yaml` | `HTTPRoute` HTTPS `longhorn.kubeadm.lab.example.io` → `longhorn-frontend:80` sur `main-gateway` |

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| **iSCSI sur chaque node** (`open-iscsi` + `nfs-common`, `iscsid` actif, module `iscsi_tcp`) — **déjà installé par `kubeadm/provision.sh`** | `longhorn-manager` et le plugin CSI appellent `iscsiadm` pour attacher les volumes. Sans lui, les pods CSI partent en `CrashLoopBackOff` avec `iscsiadm: not found` | `vagrant ssh k8s-w1 -c 'systemctl is-active iscsid && lsmod \| grep iscsi_tcp'` |
| `helm` dans le `PATH` | le chart | `helm version` |
| Namespace `longhorn-system` en PodSecurity `privileged` | les pods Longhorn sont privilégiés (iSCSI, hostPath) — **posé par `longhorn-up.sh`** | `kubectl get ns longhorn-system --show-labels` |
| `../envoy-gateway/` + `../cert-manager/` (optionnel) | uniquement pour exposer l'UI en HTTPS | `kubectl get gateway -n envoy-gateway-system` |

> ℹ️ **Tu viens du lab Talos ? Les deux prérequis lourds ont disparu.** C'est à cause d'eux que
> cet addon était le plus tordu du dépôt :
>
> | Talos | Debian |
> |---|---|
> | **Extensions système** `iscsi-tools` + `util-linux-tools`, *cuites* dans l'image de l'installeur. Un node sans elles n'était pas réparable à chaud — il fallait le réinstaller ou l'upgrader vers une nouvelle ref Image Factory. `longhorn-up.sh` ne pouvait que *vérifier* (`talosctl get extensions`) et refuser d'aller plus loin. | Deux **paquets apt**. `kubeadm/provision.sh` fait `apt-get install -y open-iscsi nfs-common`, `systemctl enable --now iscsid` et charge `iscsi_tcp` (`/etc/modules-load.d/iscsi.conf`) sur **chaque** node, au provisioning. Rien à vérifier, rien à cuire. |
> | **Montage kubelet `rshared`** sur `/var/lib/longhorn`, appliqué par `talosctl patch mc` : le kubelet Talos tourne dans un conteneur et n'a pas la propagation de montage bidirectionnelle. | `/var/lib/longhorn` est un dossier ordinaire du système de fichiers racine, et le kubelet tourne directement sur l'hôte : la propagation de montage est déjà bonne. Rien à patcher. |
>
> Conséquence : plus de `talosctl`, plus de `TALOSCONFIG`, et les fichiers `patch-longhorn.yaml`
> et `schematic.yaml` **n'existent plus** dans ce dépôt. Le script d'install passe de 5 étapes
> à 3.

## ⚡ Installation

Version épinglée : chart **Longhorn 1.12.0**.

```bash
./_k8s/longhorn/longhorn-up.sh
```

Idempotent : relançable sans casse (`helm upgrade --install`). Il couvre les **deux** étapes
ci-dessous. Il **compte les workers planifiables sur le cluster réel** (plutôt que de faire
confiance à `WORKERS` de `lab.env`, qui n'exprime qu'une intention) et aligne le nombre de
réplicas bloc dessus, plafonné à 3. `REPLICAS=…` force la valeur, `LONGHORN_VERSION=…` surcharge
la version du chart.

> ℹ️ Avec `WORKERS=0`, les control planes sont déteintés (`UNTAINT_CP=auto`) et deviennent les
> seuls nodes de stockage : le script les compte au lieu de s'arrêter.

### 1. Namespace + Pod Security — *automatisé par `longhorn-up.sh`*

```bash
kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite
```

> ℹ️ Un cluster kubeadm n'applique **aucun** niveau PodSecurity par défaut : ces étiquettes ne
> changent rien aujourd'hui. On les garde parce qu'elles **documentent l'intention** et gardent
> le namespace fonctionnel si le cluster est durci plus tard
> (`--admission-control-config-file` sur l'apiserver).

### 2. Chart Helm + StorageClass socle — *automatisé par `longhorn-up.sh`*

```bash
helm repo add longhorn https://charts.longhorn.io && helm repo update
# --version : épingle ; vérifier la dernière sur charts.longhorn.io
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version 1.12.0 \
  -f _k8s/longhorn/values.yaml
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer
kubectl apply -f _k8s/longhorn/longhorn-r1-storageclass.yaml
```

## 🔧 Sous le capot

### Pourquoi `longhorn-r1` (1 réplica)

Le `Vagrantfile` n'attache **aucun disque supplémentaire** : Longhorn partage le disque unique
de la box avec l'OS, les images conteneurs et etcd. Empiler des volumes 3-réplicas y déclenche
des `ReplicaSchedulingFailure` (et des évictions `DiskPressure` avant ça). `longhorn-r1` divise
la conso par ~3 pour les cas où la réplication bloc est superflue : donnée reconstructible
(Prometheus, Loki) ou déjà répliquée par l'appli (CloudNativePG, 3 instances). Définie **une
seule fois** ici, consommée ailleurs.

> ℹ️ Sur une base **critique**, rester sur `longhorn` (3 réplicas) ou déléguer explicitement
> la résilience à l'application.

### Disque dédié (setup « propre », optionnel)

Longhorn 1.10+ recommande un disque dédié. Ici, par défaut, on reste sur `/var/lib/longhorn`
(disque unique de la box). Pour faire propre :

1. **VirtualBox** : attacher un `.vdi` supplémentaire par worker (contrôleur SATA, port
   suivant) — nécessite un ajout dans le `Vagrantfile` (bloc
   `vb.customize ["createhd", …]` / `["storageattach", …]`).
2. **Debian** : partitionner, formater et monter de façon persistante, puis pointer
   `defaultDataPath` dessus :
   ```bash
   sudo mkfs.ext4 -L longhorn /dev/sdb
   echo 'LABEL=longhorn /mnt/longhorn ext4 defaults 0 2' | sudo tee -a /etc/fstab
   sudo mkdir -p /mnt/longhorn && sudo mount -a
   ```
   ```bash
   helm upgrade longhorn longhorn/longhorn -n longhorn-system \
     --reuse-values --set defaultSettings.defaultDataPath=/mnt/longhorn
   ```
   Aucun patch de propagation de montage à faire — c'était une contrainte Talos.

## ✅ Vérifier

```bash
vagrant ssh k8s-w1 -c 'systemctl is-active iscsid'   # active
vagrant ssh k8s-w1 -c 'lsmod | grep iscsi_tcp'       # module chargé
kubectl -n longhorn-system get pods              # instance-manager, manager, csi-* Running
kubectl get storageclass                         # longhorn (default) + longhorn-r1
kubectl -n longhorn-system get nodes.longhorn.io # chaque node "Schedulable", disque Ready

# Test rapide : un PVC doit se lier
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: test-longhorn }
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn
  resources: { requests: { storage: 1Gi } }
EOF
kubectl get pvc test-longhorn                    # Bound
kubectl delete pvc test-longhorn
```

> ℹ️ Longhorn livre un **script de vérification d'environnement** qui audite chaque node (iSCSI,
> NFS, `multipathd`, modules noyau) — le moyen le plus rapide de confirmer les prérequis
> Debian :
> `curl -sSfL https://raw.githubusercontent.com/longhorn/longhorn/v1.12.0/scripts/environment_check.sh | bash`

## 🌐 Accès

`longhorn-up.sh` a déjà appliqué l'`HTTPRoute` (son étape `[3/3]`). Pour la réappliquer seule :

```bash
kubectl apply -f _k8s/longhorn/httproute.yaml
```

> 🌐 **Domaine** : le manifeste porte le domaine neutre `kubeadm.lab.example.io` (dépôt public).
> `longhorn-up.sh` y substitue `LAB_DOMAIN` à la volée ; appliqué à la main comme ci-dessus, le
> domaine neutre reste. Substitue-le toi-même :
>
> ```bash
> sed 's/kubeadm\.lab\.example\.io/kubeadm.lab.mon-domaine.tld/g' \
>   _k8s/longhorn/httproute.yaml | kubectl apply -f -
> ```
>
> (cf. [`../LISEZ-MOI.md`](../LISEZ-MOI.md#-lab_domain--le-domaine-des-ui)).

| Interface | URL / commande | Auth |
|---|---|---|
| UI Longhorn (HTTPS via `main-gateway`) | `https://longhorn.kubeadm.lab.example.io` | **aucune** |
| Sans exposition | `kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80` | — |

Cert wildcard `*.kubeadm.lab.example.io` déjà porté par l'écouteur `https` : rien à émettre ici,
quel que soit le mode TLS du lab (auto-signé par défaut, ou cert-manager — le Secret porte le
même nom dans les deux cas, cf. [`../self-signed/LISEZ-MOI.md`](../self-signed/LISEZ-MOI.md)).

> ⚠️ **L'UI Longhorn n'a aucune authentification.** Exposée ainsi, elle est accessible à
> quiconque atteint le VIP (via Tailscale) — et elle permet de supprimer des volumes. Pour la
> protéger : `SecurityPolicy` Envoy Gateway (Basic Auth / OIDC) ciblant cette `HTTPRoute`.

## ⚠️ Pièges

- **`defaultReplicaCount` > nombre de nodes de stockage** → volumes coincés en `Degraded`, à
  vie. `longhorn-up.sh` l'aligne sur les nodes qu'il compte ; en installant le chart à la main,
  le faire soi-même (à 1 worker, mettre `1`).
- **Deux StorageClass par défaut** si `../local-path-storage/` est aussi installé :
  `values.yaml` pose `persistence.defaultClass: true` (⇒ `longhorn`) et
  `local-path-storage.yaml` annote `local-path` avec `is-default-class: "true"`. Un PVC sans
  `storageClassName` devient alors **non déterministe**. Choisir un seul défaut :
  ```bash
  kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class-
  # ou, dans l'autre sens : helm upgrade ... --set persistence.defaultClass=false
  ```
- **`iscsid` arrêté** (ou un node monté hors de `kubeadm/provision.sh`) → pods CSI en
  `CrashLoopBackOff`, erreurs `iscsiadm: not found` / `Failed to execute iscsiadm`. Sur le node :
  `sudo apt-get install -y open-iscsi && sudo systemctl enable --now iscsid`.
- **`multipath-tools` (`multipathd`)** : Debian 13 ne l'installe **pas**, et c'est précisément
  pour ça que Longhorn fonctionne d'emblée ici. Si tu l'installes pour autre chose, `multipathd`
  s'approprie les devices bloc de Longhorn et les volumes ne s'attachent plus
  (`failed to get devicemapper`). Les blacklister dans `/etc/multipath.conf`
  (`devices { device { vendor "IET" ... } }`), ou ne pas installer le paquet.
- **Disque partagé** : Longhorn sur `/var/lib/longhorn` consomme le même système de fichiers que
  l'OS, les images conteneurs et etcd → surveiller `DiskPressure`, préférer `longhorn-r1`, ou
  passer au disque dédié (ci-dessus).
- **`vagrant destroy` d'un worker détruit ses réplicas.** Sur `longhorn` (3 réplicas) Longhorn
  reconstruit ailleurs ; sur `longhorn-r1` (1 réplica) **la donnée est perdue**. Drainer et
  laisser Longhorn reconstruire avant de retirer un node qui stocke quelque chose d'important.
- **Désinstallation** : passer le setting Longhorn `deleting-confirmation-flag` à `true`
  avant `helm uninstall`, sinon la suppression reste bloquée.

## 📚 Références

- [Longhorn — Prérequis d'installation (1.12)](https://longhorn.io/docs/1.12.0/deploy/install/#installation-requirements)
- [Longhorn — Quick Installation](https://longhorn.io/docs/1.12.0/deploy/install/)
- `kubeadm/provision.sh` — là où `open-iscsi`, `nfs-common` et le module `iscsi_tcp` sont posés.
