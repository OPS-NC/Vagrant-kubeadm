<!-- i18n -->
[English](UPGRADE.md) · **Français**
<!-- /i18n -->

# ⬆️ Monter Kubernetes de version

> Comment faire passer ce lab d'une version de Kubernetes à la suivante **avec kubeadm**, comme
> sur un vrai cluster. Parcours d'installation : [`../LISEZ-MOI.md`](../LISEZ-MOI.md) ·
> symptômes et correctifs : [`../DEPANNAGE.md`](../DEPANNAGE.md).

Référence au moment de l'écriture : Kubernetes **1.36.3**, dépôt apt **`v1.36`**, containerd
**2.2.6**, Cilium **1.20.0**, `CNI=cilium`. Adapte les noms de nodes et les IP à ta topologie
(`lab.env`) ; le défaut du dépôt est 1 control plane + 2 workers.

> ⚠️ Contrairement au dépôt jumeau Talos de ce lab, la procédure ci-dessous n'a **pas** été
> chronométrée sur une exécution réelle. C'est la procédure kubeadm amont, transposée aux
> variables et aux scripts de ce dépôt. Chaque commande est reprise de la documentation amont
> citée en §7.

---

## 🎯 1. Les deux règles qu'on ne contourne pas

### Une MINEURE à la fois

**Sauter une mineure n'est pas supporté.** `1.36 → 1.37 → 1.38`, jamais `1.36 → 1.38`. Ce n'est
pas une lubie de kubeadm : la politique de dépréciation de l'API interdit à `kube-apiserver` de
sauter une mineure, même sur un cluster à instance unique. `kubeadm upgrade apply` refuse une
cible à plus d'une mineure de la version courante.

Les versions de patch à l'intérieur d'une mineure sont libres (`1.36.3 → 1.36.7`).

### Le kubelet ne doit jamais dépasser l'apiserver

| Composant | Autorisé par rapport à `kube-apiserver` |
|---|---|
| `kube-apiserver` (HA, plusieurs control planes) | à **1 mineure** les uns des autres |
| `kubelet` | jusqu'à **3 mineures en retard** — **jamais en avance** |
| `kubectl` | 1 mineure de part et d'autre |

C'est ce qui dicte l'ordre de toute la procédure : **le control plane d'abord, le kubelet en
dernier**. Monter le paquet `kubelet` d'un node avant d'avoir lancé `kubeadm upgrade apply`
place un kubelet 1.37 devant un apiserver 1.36 — combinaison non supportée, qui échoue de façon
laide.

> ⚠️ **Ne lance jamais `vagrant provision` pour « monter » le lab.** `kubeadm/provision.sh` lève
> le `hold` et installe `kubelet`, `kubeadm` et `kubectl` en `K8S_VERSION` avec
> `--allow-change-held-packages`, **sur tous les nodes d'un coup**, sans jamais appeler
> `kubeadm upgrade`. Bumper `lab.env` puis reprovisionner ferait donc sauter tous les kubelet à
> la nouvelle mineure alors que le control plane est encore sur l'ancienne. `vagrant provision`
> est fait pour une VM **neuve**, pas pour une montée de version.

---

## 📦 2. Pourquoi les paquets sont en `hold`, et pourquoi le dépôt apt est par MINEURE

### `apt-mark hold` est délibéré

`kubeadm/provision.sh` termine son étape paquets par :

```bash
apt-mark hold kubelet kubeadm kubectl
```

Une montée de version doit être un **geste délibéré**, jamais l'effet de bord d'un `apt upgrade`
lancé dans une VM — qui casserait silencieusement le skew kubelet/apiserver. La première étape
de toute montée est donc `apt-mark unhold`, et la dernière un `apt-mark hold` de nouveau.

Vérifier ce qui est retenu :

```bash
vagrant ssh k8s-cp1 -c "apt-mark showhold"
```

### Le dépôt `pkgs.k8s.io` est par mineure — c'est l'étape que tout le monde rate

Il y a **un dépôt apt par mineure Kubernetes** :

```
https://pkgs.k8s.io/core:/stable:/v1.36/deb/
```

Le dépôt `v1.36` ne proposera **jamais** la 1.37. Y rester, c'est obtenir de
`apt-get install kubeadm=1.37.x-*` un *« Version '1.37.x-*' for 'kubeadm' was not found »* — et
en conclure que la version n'existe pas.

Dans ce lab, le fichier de dépôt est généré par `provision.sh` à partir de **`K8S_APT_MINOR`**,
et la version du paquet à partir de **`K8S_VERSION`**. Les deux vivent dans `lab.env` et **les
deux doivent bouger ensemble** :

```bash
# lab.env
K8S_VERSION=1.37.0
K8S_APT_MINOR=v1.37
```

> ⚠️ Ces deux variables ont aussi des **défauts dupliqués** dans le `Vagrantfile`
> (`K8S_VERSION`, `K8S_APT_MINOR`) et dans `kubeadm/cluster-up.sh` (`K8S_VERSION`). Ils existent
> pour qu'un lab monté sans `lab.env` fonctionne quand même. Bumpe-les **dans le même commit**
> que `lab.env.example`, sinon un lab construit sans `lab.env` repart sur l'ancienne version.

---

## 🧭 3. La voie du lab : détruire et reconstruire

Soyons francs : sur un lab **jetable**, le chemin le plus rapide et le plus sûr n'est pas la
montée de version.

```bash
# lab.env : K8S_VERSION=1.37.0 et K8S_APT_MINOR=v1.37
vagrant destroy -f
vagrant up
./kubeadm/cluster-up.sh
export KUBECONFIG="$PWD/kubeconfig" LAB_DIR="$PWD"
./_k8s/install.sh kubeadm platform
```

On obtient un cluster propre sur la version cible, sans état à moitié migré, en à peu près le
temps que prendrait une montée roulante prudente sur trois nodes — et sans aucun de ses risques.

**Alors pourquoi documenter la vraie procédure ?** Parce que l'apprendre est tout l'intérêt d'un
lab kubeadm. Un cluster managé se met à jour tout seul ; un cluster kubeadm non, et le jour où
il faudra le faire sur quelque chose qu'on ne peut pas détruire, c'est cette séquence-là qu'il
faudra connaître. Fais-la ici d'abord, là où une erreur coûte un `vagrant destroy`.

Utilise le §4 quand tu veux **t'entraîner à la montée de version**. Utilise cette section quand
tu veux juste la nouvelle version.

---

## ⚡ 4. La vraie procédure, sur un cluster en route

Tout ce qui suit se lance **dans les VM** (`vagrant ssh <node>`), sauf les commandes `kubectl`
qui se lancent depuis l'hôte avec `KUBECONFIG=$PWD/kubeconfig`.

Partout, `1.37.x` désigne la version de patch cible exacte (par exemple le `1.37.0` de
`1.37.0-1.1`). Le suffixe `-*` des lignes `apt-get install` est volontaire : la révision Debian
n'est pas toujours `-1.1`.

### 4.1 Pré-vol — ne jamais partir d'un cluster déjà dégradé

```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide                 # tous les nodes Ready, tous sur la même version
kubectl get pods -A | grep -v Running     # rien de cassé avant de commencer
kubectl get --raw='/healthz/etcd'         # etcd en bonne santé
vagrant ssh k8s-cp1 -c "sudo kubeadm certs check-expiration"
```

Lis d'abord le [changelog](https://git.k8s.io/kubernetes/CHANGELOG) de la version cible, et
vérifie deux contraintes propres à ce lab :

| Contrainte | Pourquoi c'est important ici |
|---|---|
| **containerd 2.x** | le repli CRI `RuntimeConfig` disparaît en **1.37**. Un lab monté avec `CONTAINERD_SOURCE=debian` (containerd 1.7) transforme son *avertissement* 1.36 en *échec* 1.37. Vérifie `containerd --version` avant de monter. |
| **Cilium ↔ Kubernetes** | Cilium ne supporte qu'un ensemble borné de versions Kubernetes. Consulte ses notes de version et planifie le §6 en conséquence. |
| **Le swap doit être coupé** | déjà géré par `provision.sh`, mais un swap réactivé à la main fait échouer le preflight. |

> 💡 `kubeadm upgrade` tire de nouvelles images de control plane. Avec `REGISTRY_MIRROR`
> renseigné elles viennent du miroir ; sinon le node a besoin d'Internet par sa carte NAT.

### 4.2 Premier control plane (`k8s-cp1`)

```bash
vagrant ssh k8s-cp1
```

```bash
# 1. Pointer apt sur le dépôt de la NOUVELLE mineure
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

# 2. Monter kubeadm SEUL
sudo apt-mark unhold kubeadm && \
sudo apt-get update && sudo apt-get install -y kubeadm='1.37.x-*' && \
sudo apt-mark hold kubeadm
kubeadm version

# 3. Que se passerait-il ?
sudo kubeadm upgrade plan

# 4. Appliquer — c'est l'étape qui monte les composants du control plane
sudo kubeadm upgrade apply v1.37.x
```

`kubeadm upgrade apply` réécrit les manifestes de pods statiques de `kube-apiserver`,
`kube-controller-manager`, `kube-scheduler` et `etcd`, et **renouvelle les certificats qu'il
gère sur ce node** (cf. §5).

> ⚠️ Avec `CONTROL_PLANES=1`, l'API est **indisponible** le temps que les pods statiques
> redémarrent. C'est attendu sur un control plane unique, et c'est le meilleur argument pour
> s'entraîner sur une topologie à 3 CP.

Ensuite seulement, le kubelet :

```bash
# 5. Drainer le node (depuis l'HÔTE, ou dans la VM — le kubeconfig y est aussi)
kubectl drain k8s-cp1 --ignore-daemonsets

# 6. Monter kubelet et kubectl
sudo apt-mark unhold kubelet kubectl && \
sudo apt-get update && sudo apt-get install -y kubelet='1.37.x-*' kubectl='1.37.x-*' && \
sudo apt-mark hold kubelet kubectl

# 7. Redémarrer le kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# 8. Remettre le node en service
kubectl uncordon k8s-cp1
```

> 💡 Si le drain bloque sur un pod à `emptyDir`, ajoute `--delete-emptydir-data`. S'il bloque
> sur un PodDisruptionBudget (Longhorn est le suspect habituel), corrige le PDB plutôt que de
> forcer — et sur un lab, `--disable-eviction` est l'outil brutal de dernier recours.

Vérifie avant de continuer :

```bash
kubectl get nodes            # k8s-cp1 Ready, VERSION v1.37.x
kubectl get --raw='/healthz/etcd'
```

### 4.3 Les autres control planes (`k8s-cp2`, `k8s-cp3`)

**Un node à la fois**, avec un contrôle d'etcd entre chaque. Avec 3 control planes le quorum est
à 2 : en perdre deux d'un coup fige l'API.

La seule différence avec le §4.2 tient aux étapes 3–4 — `kubeadm upgrade node` remplace
`plan` + `apply` :

```bash
# 1. Même changement de dépôt, même montée de kubeadm
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-mark unhold kubeadm && \
sudo apt-get update && sudo apt-get install -y kubeadm='1.37.x-*' && \
sudo apt-mark hold kubeadm

# 2. Monter les composants de control plane de CE node
sudo kubeadm upgrade node

# 3. Drain, kubelet, redémarrage, uncordon — identique au §4.2
kubectl drain k8s-cp2 --ignore-daemonsets
sudo apt-mark unhold kubelet kubectl && \
sudo apt-get update && sudo apt-get install -y kubelet='1.37.x-*' kubectl='1.37.x-*' && \
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet
kubectl uncordon k8s-cp2
```

> ⚠️ La VIP `192.168.56.5` se déplace toute seule pendant qu'un control plane redémarre : le
> test de santé de keepalived (`/livez/ping` toutes les 3 s, `weight -30`) fait passer le node en
> cours de redémarrage derrière un pair sain. C'est exactement la bascule que ce lab existe pour
> démontrer — regarde-la se produire :
> ```bash
> while true; do curl -sk -o /dev/null -w '%{http_code} ' https://192.168.56.5:6443/livez; sleep 1; done
> ```

### 4.4 Les workers (`k8s-w1`, `k8s-w2`, …)

Comme au §4.3, un node à la fois. Les workers n'hébergent aucun membre etcd : rien ici ne peut
casser le quorum — mais les drainer tous d'un coup couperait toutes les charges.

```bash
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-mark unhold kubeadm && \
sudo apt-get update && sudo apt-get install -y kubeadm='1.37.x-*' && \
sudo apt-mark hold kubeadm

sudo kubeadm upgrade node       # sur un worker, ne met à jour que la config locale du kubelet

kubectl drain k8s-w1 --ignore-daemonsets
sudo apt-mark unhold kubelet kubectl && \
sudo apt-get update && sudo apt-get install -y kubelet='1.37.x-*' kubectl='1.37.x-*' && \
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet
kubectl uncordon k8s-w1
```

### 4.5 Après la montée de version

```bash
kubectl get nodes -o wide            # tous les nodes Ready, tous en v1.37.x
kubectl get pods -A | grep -v Running
kubectl version
```

Puis **réécris la nouvelle version dans le dépôt**, pour qu'une reconstruction future reparte
d'où tu t'es arrêté :

| Fichier | Ce qu'il faut changer |
|---|---|
| `lab.env` | `K8S_VERSION=1.37.x` **et** `K8S_APT_MINOR=v1.37` |
| `lab.env.example` | les deux mêmes lignes (c'est le modèle versionné) |
| `Vagrantfile` | les défauts de repli `K8S_VERSION` / `K8S_APT_MINOR` |
| `kubeadm/cluster-up.sh` | le défaut de repli `K8S_VERSION` |

> ⚠️ Trois de ces quatre fichiers portent un défaut **dupliqué** exprès (filet de sécurité quand
> `lab.env` manque). Deux défauts divergents produisent un lab incohérent : des paquets d'une
> mineure, une configuration générée pour une autre.

---

## 🔐 5. Les certificats

kubeadm émet des certificats client et serveur valables **1 an**, signés par une AC valable
**10 ans**.

```bash
vagrant ssh k8s-cp1 -c "sudo kubeadm certs check-expiration"
```

**Une montée de version les renouvelle pour toi.** `kubeadm upgrade` (aussi bien `apply` que
`node`) renouvelle automatiquement les certificats qu'il gère sur ce node —
`--certificate-renewal=false` permet de s'y soustraire. Un cluster monté de version au moins une
fois par an ne voit donc jamais de certificat expiré : c'est précisément pour ça que
l'expiration annuelle mord rarement en production, et systématiquement sur une VM de lab laissée
suspendue pendant des mois.

Renouvellement manuel, quand aucune montée de version n'est prévue :

```bash
vagrant ssh k8s-cp1
sudo kubeadm certs renew all
sudo systemctl restart kubelet    # recharge les pods statiques du control plane
```

> ⚠️ Le renouvellement touche aussi `admin.conf`, dont le `kubeconfig` de l'hôte a été copié.
> Rafraîchis-le, sinon `kubectl` continue de présenter l'ancien certificat client :
> ```bash
> vagrant ssh k8s-cp1 -c "sudo cp /etc/kubernetes/admin.conf /vagrant/_out/admin.conf"
> cp -f _out/admin.conf kubeconfig && chmod 0600 kubeconfig
> ```

Deux choses que kubeadm ne renouvelle **pas** : l'AC elle-même (10 ans — bien au-delà de la vie
d'un lab), et le certificat client du kubelet, qui tourne automatiquement sous
`/var/lib/kubelet/pki`.

> ℹ️ À ne pas confondre avec les deux éléments à courte durée de vie qui servent à **joindre**
> un node : le token de bootstrap (24 h) et la clé de certificats (2 h).
> `kubeadm/node-init.sh` régénère les deux à chaque passage de `cluster-up.sh` — cf.
> [`../DEPANNAGE.md`](../DEPANNAGE.md).

---

## 🧩 6. containerd et Cilium montent sur leurs propres cycles

Kubernetes, le runtime de conteneurs et le CNI sont **trois trains de versions indépendants**.
Les bouger ensemble, c'est transformer une simple montée de version en casse-tête insoluble :
monte une chose à la fois, et vérifie le cluster entre chaque.

### containerd

`containerd.io` n'est **pas** retenu par `provision.sh` — seuls `kubelet`, `kubeadm` et
`kubectl` le sont. Il bouge donc avec un simple `apt upgrade` dans une VM, ce qui est
généralement sans conséquence mais redémarre toujours tous les conteneurs de ce node.

```bash
kubectl drain k8s-w1 --ignore-daemonsets
vagrant ssh k8s-w1 -c "sudo apt-get update && sudo apt-get install -y --only-upgrade containerd.io"
vagrant ssh k8s-w1 -c "containerd --version"
kubectl uncordon k8s-w1
```

> ⚠️ **Le piège de la migration 1.7 → 2.x.** La clé de l'image `pause` a changé de **nom et
> d'emplacement** entre les deux formats de configuration :
> - v2 (containerd 1.7) : `sandbox_image = "…"` sous `[plugins."io.containerd.grpc.v1.cri"]`
> - v3 (containerd 2.x) : `sandbox = '…'` sous
>   `[plugins.'io.containerd.cri.v1.images'.pinned_images]`
>
> Une config recopiée telle quelle perd le réglage silencieusement. `provision.sh` contourne le
> problème en régénérant `/etc/containerd/config.toml` depuis `containerd config default` à
> chaque passage et en patchant **les deux** noms de clé — c'est aussi pour ça qu'il ne faut pas
> éditer ce fichier à la main en espérant que ça survive.

Dans l'autre sens, passer de `CONTAINERD_SOURCE=docker` à `debian` est une **régression vers une
impasse** : containerd 1.7 n'implémentera jamais `RuntimeConfig` et ne peut pas t'emmener
au-delà de la 1.36.

### Cilium

```bash
# lab.env : CILIUM_VERSION=1.2x.y
export KUBECONFIG="$PWD/kubeconfig" LAB_DIR="$PWD"
./_k8s/cilium/cilium-up.sh kubeadm
```

À lancer **depuis la racine du dépôt** : `_k8s/` est le sous-module [k8s-playground](https://github.com/OPS-NC/k8s-playground),
il prend la distribution en premier argument, et il lit `lab.env` / `_out/` via `LAB_DIR` —
sans cet export, il repartirait sur ses propres valeurs par défaut.

Le script est un `helm upgrade --install` : c'est donc la même commande qu'on installe ou qu'on
monte de version. Lis d'abord les notes de montée de version de Cilium : un saut de mineure peut
imposer une étape de pré-vol ponctuelle, et ce lab dépend de deux fonctions Cilium qui doivent
continuer de marcher — `kubeProxyReplacement` (il n'y a **aucun** kube-proxy sur lequel se
rabattre quand `KUBE_PROXY_REPLACEMENT=true`) et l'annonce L2 qui donne son IP au Gateway Envoy.

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n envoy-gateway-system get svc      # le Gateway doit garder son EXTERNAL-IP
```

### Tout le reste dans les VM

Les paquets Debian (keepalived compris) suivent un simple `apt upgrade`. C'est sans risque
précisément parce que `kubelet`/`kubeadm`/`kubectl` sont en `hold` :

```bash
vagrant ssh k8s-cp1 -c "sudo apt-get update && sudo apt-get -y upgrade"
```

---

## 📚 Références

- [kubeadm — Upgrading kubeadm clusters](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/)
- [Kubernetes — Version skew policy](https://kubernetes.io/releases/version-skew-policy/)
- [kubeadm — Certificate management](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/)
- [Kubernetes — Installing kubeadm (dépôts apt)](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [Cilium — Upgrade guide](https://docs.cilium.io/en/stable/operations/upgrade/)
- [`../DEPANNAGE.md`](../DEPANNAGE.md) — symptômes et correctifs
