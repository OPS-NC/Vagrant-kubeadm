<!-- i18n -->
[English](UPGRADE.md) · **Français**
<!-- /i18n -->

# ⬆️ Monter Kubernetes de version

> Faire passer ce lab d'une version de Kubernetes à la suivante **avec kubeadm**, comme sur un
> vrai cluster. Parcours d'installation : [`../LISEZ-MOI.md`](../LISEZ-MOI.md) · symptômes :
> [`../DEPANNAGE.md`](../DEPANNAGE.md).

Référence au moment de l'écriture : Kubernetes **1.36.3**, dépôt apt **`v1.36`**, containerd
**2.2.6**, Cilium **1.20.0**, `CNI=cilium`. Adapte les noms de nodes et les IP à ta topologie
(`lab.env`) ; le défaut du dépôt est 1 control plane + 2 workers.

> ⚠️ Contrairement au lab Talos jumeau, cette procédure n'a **pas** été chronométrée sur une
> exécution réelle. C'est la procédure kubeadm amont transposée aux variables et aux scripts de ce
> dépôt ; chaque commande est citée de la documentation liée au §6.

---

## 🎯 1. Les deux règles non négociables

**Un seul MINOR à la fois.** `1.36 → 1.37 → 1.38`, jamais `1.36 → 1.38`. Ce n'est pas une
bizarrerie de kubeadm : la politique de dépréciation de l'API interdit à `kube-apiserver` de sauter
un minor, même sur un cluster à une seule instance, et `kubeadm upgrade apply` refuse une cible à
plus d'un minor de la version courante. Les versions de patch dans un minor sont libres
(`1.36.3 → 1.36.7`).

**Le kubelet ne doit jamais être en avance sur l'apiserver.**

| Composant | Autorisé par rapport à `kube-apiserver` |
|---|---|
| `kube-apiserver` (HA, plusieurs control planes) | à **1 minor** l'un de l'autre |
| `kubelet` | jusqu'à **3 minors plus ancien** — **jamais plus récent** |
| `kubectl` | 1 minor de part et d'autre |

C'est ce qui dicte l'ordre de toute la procédure : **le control plane d'abord, le kubelet en
dernier**. Monter le paquet `kubelet` d'un node avant que `kubeadm upgrade apply` ait tourné place
un kubelet 1.37 devant un apiserver 1.36.

> ⚠️ **Ne lance jamais `vagrant provision` pour « mettre à jour » le lab.** `provision.sh` dégèle
> les paquets et installe `kubelet`/`kubeadm`/`kubectl` à `K8S_VERSION` avec
> `--allow-change-held-packages`, **sur tous les nodes d'un coup**, sans jamais appeler
> `kubeadm upgrade`. Incrémenter `lab.env` puis reprovisionner ferait sauter tous les kubelets au
> nouveau minor pendant que le control plane est encore sur l'ancien. `vagrant provision` est fait
> pour une VM **neuve**.

---

## 📦 2. Paquets gelés, et un dépôt apt par MINOR

`provision.sh` termine son étape paquets par `apt-mark hold kubelet kubeadm kubectl`. Une montée de
version doit être un acte délibéré, jamais l'effet de bord d'un `apt upgrade` dans une VM — qui
casserait en silence l'écart kubelet/apiserver. Toute montée commence donc par un `apt-mark unhold`
et finit par un `apt-mark hold`. Vérification :
`vagrant ssh k8s-cp1 -c "apt-mark showhold"`.

**Il y a un dépôt apt par minor de Kubernetes**, et c'est l'étape que tout le monde rate :

```
https://pkgs.k8s.io/core:/stable:/v1.36/deb/
```

Le dépôt `v1.36` n'offrira **jamais** la 1.37. Y rester fait répondre à
`apt-get install kubeadm=1.37.x-*` : *« Version '1.37.x-*' for 'kubeadm' was not found »* — et on
en conclut que la version n'existe pas.

Ici le fichier de dépôt est généré depuis **`K8S_APT_MINOR`** et la version du paquet depuis
**`K8S_VERSION`**. Les deux vivent dans `lab.env` et **doivent bouger ensemble** :

```bash
# lab.env
K8S_VERSION=1.37.0
K8S_APT_MINOR=v1.37
```

> ⚠️ Les deux ont aussi des **défauts de repli dupliqués** dans le `Vagrantfile` et dans
> `kubeadm/cluster-up.sh` (`K8S_VERSION` seulement là), pour qu'un lab sans `lab.env` fonctionne
> quand même. Incrémente-les dans le même commit que `lab.env.example`, sinon un lab construit sans
> `lab.env` repart sur l'ancienne version.

---

## 🧭 3. Le raccourci du lab : détruire et reconstruire

Sur un lab jetable, le chemin le plus rapide et le plus sûr n'est pas la montée de version :

```bash
# lab.env : K8S_VERSION=1.37.0 et K8S_APT_MINOR=v1.37
vagrant destroy -f
vagrant up
./kubeadm/cluster-up.sh
./_k8s/platform-up.sh
```

Cluster propre sur la version cible, sans état à moitié migré, à peu près dans le temps qu'une
montée roulante prudente prend sur trois nodes. Utilise le §4 quand tu veux **t'exercer à la montée
de version** — c'est la raison même de faire tourner un lab kubeadm, et ici une erreur coûte un
`vagrant destroy`.

---

## ⚡ 4. La vraie procédure, sur un cluster vivant

Tout se passe **dans les VM** (`vagrant ssh <node>`), sauf les commandes `kubectl`, qui tournent
depuis l'hôte avec `KUBECONFIG=$PWD/kubeconfig`. `1.37.x` représente la version de patch cible
exacte ; le suffixe `-*` des lignes `apt-get install` est volontaire, la révision Debian n'étant pas
toujours `-1.1`.

### 4.1 Pré-vol — ne jamais partir d'un cluster dégradé

```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide                 # tous les nodes Ready, tous sur la même version
kubectl get pods -A | grep -v Running     # rien de cassé avant de commencer
kubectl get --raw='/healthz/etcd'
vagrant ssh k8s-cp1 -c "sudo kubeadm certs check-expiration"
```

Lis le [changelog](https://git.k8s.io/kubernetes/CHANGELOG) de la version cible, puis vérifie deux
contraintes propres à ce lab :

| Contrainte | Pourquoi elle compte ici |
|---|---|
| **containerd 2.x** | le repli CRI `RuntimeConfig` disparaît en **1.37**, ce qui transforme un lab construit avec `CONTAINERD_SOURCE=debian` (containerd 1.7) d'un *avertissement* 1.36 en *échec* 1.37. Vérifie `containerd --version` d'abord. |
| **Cilium ↔ Kubernetes** | Cilium supporte un ensemble borné de versions de Kubernetes ; lis ses notes de version et planifie le §5 en conséquence. |

> 💡 `kubeadm upgrade` tire de nouvelles images de control plane. Avec `REGISTRY_MIRROR` défini
> elles viennent du miroir ; sinon le node a besoin d'Internet par sa carte NAT.

### 4.2 Chaque node commence par les deux mêmes étapes

Sur **chaque** node, dans l'ordre des §4.3 → §4.5 :

```bash
# 1. Pointer apt sur le dépôt du NOUVEAU minor
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

# 2. Monter kubeadm SEULEMENT
sudo apt-mark unhold kubeadm && \
sudo apt-get update && sudo apt-get install -y kubeadm='1.37.x-*' && \
sudo apt-mark hold kubeadm
kubeadm version
```

Et chaque node **finit** par les quatre mêmes :

```bash
kubectl drain <node> --ignore-daemonsets
sudo apt-mark unhold kubelet kubectl && \
sudo apt-get update && sudo apt-get install -y kubelet='1.37.x-*' kubectl='1.37.x-*' && \
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon <node>
```

> 💡 Si la vidange coince sur un pod avec un `emptyDir`, ajoute `--delete-emptydir-data`. Si elle
> coince sur un PodDisruptionBudget (Longhorn est le suspect habituel), corrige le PDB plutôt que
> de forcer ; `--disable-eviction` est l'instrument brutal de dernier recours.

Ce qui change entre les rôles de nodes, c'est seulement l'étape du milieu.

### 4.3 Premier control plane (`k8s-cp1`) — `upgrade apply`

Entre les deux blocs du §4.2 :

```bash
sudo kubeadm upgrade plan          # ce qui se passerait
sudo kubeadm upgrade apply v1.37.x # l'étape qui monte le control plane
```

`upgrade apply` réécrit les manifestes de pods statiques de `kube-apiserver`,
`kube-controller-manager`, `kube-scheduler` et `etcd`, et **renouvelle les certificats qu'il gère
sur ce node** (§5).

> ⚠️ Avec `CONTROL_PLANES=1`, l'API est **indisponible** pendant que les pods statiques roulent.
> Attendu sur un control plane unique, et le meilleur argument pour s'exercer sur une topologie à
> 3 CP.

```bash
kubectl get nodes                  # k8s-cp1 Ready, VERSION v1.37.x
kubectl get --raw='/healthz/etcd'
```

### 4.4 Les autres control planes (`k8s-cp2`, `k8s-cp3`) — `upgrade node`

**Un node à la fois**, en vérifiant etcd entre chaque : avec 3 control planes le quorum est 2, et
en perdre deux d'un coup gèle l'API. L'étape du milieu devient :

```bash
sudo kubeadm upgrade node
```

> ⚠️ La VIP `192.168.56.5` se déplace toute seule pendant le redémarrage d'un control plane — le
> contrôle de santé de keepalived (`/livez/ping` toutes les 3 s, `weight -30`) fait passer le node
> qui redémarre derrière un pair sain. Regarde le basculement se produire :
> ```bash
> while true; do curl -sk -o /dev/null -w '%{http_code} ' https://192.168.56.5:6443/livez; sleep 1; done
> ```

### 4.5 Les workers (`k8s-w1`, `k8s-w2`, …)

Même `kubeadm upgrade node` (sur un worker il ne met à jour que la config locale du kubelet), un
node à la fois. Les workers ne portent aucun membre etcd, donc rien ici ne peut casser le quorum —
mais les vidanger tous en même temps met toutes les charges de travail à terre.

### 4.6 Après la montée de version

```bash
kubectl get nodes -o wide            # tous les nodes Ready, tous en v1.37.x
kubectl get pods -A | grep -v Running
kubectl version
```

Puis réécris la nouvelle version dans le dépôt, pour qu'une reconstruction future reprenne là où tu
t'es arrêté :

| Fichier | Ce qu'il faut changer |
|---|---|
| `lab.env` | `K8S_VERSION=1.37.x` **et** `K8S_APT_MINOR=v1.37` |
| `lab.env.example` | les deux mêmes lignes (le modèle versionné) |
| `Vagrantfile` | les défauts de repli `K8S_VERSION` / `K8S_APT_MINOR` |
| `kubeadm/cluster-up.sh` | le défaut de repli `K8S_VERSION` |

Trois de ces quatre fichiers portent un défaut **dupliqué** à dessein — un filet de sécurité quand
`lab.env` manque. Deux défauts qui divergent donnent un lab incohérent : des paquets d'un minor,
une configuration générée pour un autre. `make validate-defaults` vérifie cette paire, clé par clé.

---

## 🔐 5. Certificats, containerd et Cilium

### Certificats

kubeadm émet des certificats client et serveur valables **1 an**, signés par une AC valable
**10 ans**.

```bash
vagrant ssh k8s-cp1 -c "sudo kubeadm certs check-expiration"
```

**Une montée de version les renouvelle pour toi** : `kubeadm upgrade` (`apply` comme `node`)
renouvelle les certificats qu'il gère sur ce node, sauf `--certificate-renewal=false`. Un cluster
mis à jour au moins une fois par an ne voit donc jamais de certificat expiré — ce qui explique que
l'expiration annuelle morde rarement en production et toujours sur une VM de lab laissée suspendue
des mois.

Renouvellement manuel, quand aucune montée n'est prévue :

```bash
vagrant ssh k8s-cp1
sudo kubeadm certs renew all
sudo systemctl restart kubelet    # recharge les pods statiques du control plane
```

> ⚠️ Le renouvellement touche aussi `admin.conf`, dont le `kubeconfig` de l'hôte est une copie.
> Rafraîchis-le, sinon `kubectl` continue de présenter l'ancien certificat client :
> ```bash
> vagrant ssh k8s-cp1 -c "sudo cp /etc/kubernetes/admin.conf /vagrant/_out/admin.conf"
> cp -f _out/admin.conf kubeconfig && chmod 0600 kubeconfig
> ```

Deux choses que kubeadm ne renouvelle **pas** : l'AC elle-même (10 ans, au-delà de la vie de tout
lab) et le certificat client du kubelet, qui tourne automatiquement sous `/var/lib/kubelet/pki`.
Rien de tout ça ne concerne les deux éléments à courte vie utilisés pour **joindre** un node — le
token de bootstrap (24 h) et la clé de certificats (2 h), tous deux régénérés à chaque exécution de
`cluster-up.sh`.

### containerd

Kubernetes, le runtime de conteneurs et le CNI sont **trois trains de versions indépendants**.
Monte-les un par un et vérifie le cluster entre chaque.

`containerd.io` n'est **pas** gelé par `provision.sh` : il bouge donc avec un simple `apt upgrade`
dans une VM — généralement sans conséquence, mais ça redémarre tous les conteneurs du node :

```bash
kubectl drain k8s-w1 --ignore-daemonsets
vagrant ssh k8s-w1 -c "sudo apt-get update && sudo apt-get install -y --only-upgrade containerd.io"
kubectl uncordon k8s-w1
```

`provision.sh` régénère `/etc/containerd/config.toml` depuis `containerd config default` à chaque
passage et corrige la clé `pause` que le format utilise, donc le renommage 1.7 → 2.x ne peut pas
perdre le réglage en silence — n'édite pas ce fichier à la main en espérant que ça survive.
Revenir à `CONTAINERD_SOURCE=debian` est une **régression vers une impasse** : containerd 1.7
n'implémentera jamais `RuntimeConfig` et ne peut pas te porter au-delà de la 1.36.

### Cilium

```bash
# lab.env : CILIUM_VERSION=1.2x.y
./_k8s/cilium/cilium-up.sh
```

Lance-le depuis la racine du dépôt ; le sous-module
[k8s-playground](https://github.com/OPS-NC/k8s-playground) trouve le lab et la distribution tout
seul. Le script est un `helm upgrade --install`, donc c'est la même commande à l'installation et à
la montée. Lis d'abord les notes de montée de Cilium : un changement de minor peut demander une
étape préalable unique, et ce lab dépend de deux fonctions Cilium qui doivent continuer de marcher —
`kubeProxyReplacement` (il n'y a **pas de kube-proxy** sur lequel se rabattre) et l'annonce L2 qui
donne son IP au Gateway Envoy.

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n envoy-gateway-system get svc      # le Gateway doit garder son EXTERNAL-IP
```

Tout le reste dans les VM (keepalived compris) suit un simple `apt upgrade`, ce qui est sans risque
précisément parce que `kubelet`/`kubeadm`/`kubectl` sont gelés.

---

## 📚 Références

- [kubeadm — Upgrading kubeadm clusters](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/)
- [Kubernetes — Version skew policy](https://kubernetes.io/releases/version-skew-policy/)
- [kubeadm — Certificate management](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/)
- [Kubernetes — Installing kubeadm (dépôts apt)](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [Cilium — Upgrade guide](https://docs.cilium.io/en/stable/operations/upgrade/)
- [`../DEPANNAGE.md`](../DEPANNAGE.md) — symptômes et remèdes
