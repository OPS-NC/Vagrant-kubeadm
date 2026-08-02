<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🏠 ☸️ Vagrant-KubeADM

> **Kubernetes 1.36 à la main — `kubeadm` sur des VM Debian 13, sous VirtualBox.** `vagrant up`
> prépare les machines, un script enchaîne les commandes `kubeadm`, et une couche applicative
> complète (Cilium, Envoy Gateway, Longhorn, Vault, PostgreSQL…) vient par-dessus. Un seul
> control plane, ou HA avec 3 CP derrière une VIP keepalived.

Chaque VM est une Debian ordinaire avec SSH et `apt`, et chaque étape des scripts est une
commande `kubeadm` que tu pourrais taper toi-même — le §5 montre exactement lesquelles. Ce que le
dépôt ajoute, c'est la partie ingrate : la VIP qui doit exister *avant* `kubeadm init`, le
`node-ip` que tous les labs Vagrant ratent, la config containerd 2.x, les SAN de certificat
qu'on ne peut pas ajouter après coup.

```bash
git clone --recurse-submodules https://github.com/OPS-NC/Vagrant-kubeadm.git
cd Vagrant-kubeadm
cp lab.env.example lab.env      # choisir la topologie
vagrant up                      # crée et PRÉPARE les VM (aucun cluster encore)
./kubeadm/cluster-up.sh         # kubeadm init + join + kubeconfig
./_k8s/platform-up.sh           # CNI, Envoy Gateway, metrics-server, TLS wildcard
```

| | |
|---|---|
| 📖 **Doc navigable** | [ops-nc.github.io/Vagrant-kubeadm](https://ops-nc.github.io/Vagrant-kubeadm/) — EN/FR, clair/sombre, copie hors-ligne avec `make docs` |
| 📦 **Couche applicative** | [ops-nc.github.io/k8s-playground](https://ops-nc.github.io/k8s-playground/) — son propre dépôt, monté ici en sous-module `_k8s/` |
| ⬆️ **Montées de version** | [`kubeadm/MISE-A-JOUR.md`](kubeadm/MISE-A-JOUR.md) |
| 🚑 **Quelque chose casse ?** | [`DEPANNAGE.md`](DEPANNAGE.md) |

> ⚠️ **`--recurse-submodules` n'est pas optionnel.** `_k8s/` est un sous-module git ; un
> `git clone` simple le laisse **vide** et `./_k8s/platform-up.sh` répond
> `No such file or directory`. Sur un clone déjà fait :
> `git submodule update --init --recursive`.

> ℹ️ **Il existe un lab jumeau, [Vagrant-Talos](https://github.com/OPS-NC/Vagrant-Talos)** — même
> plan d'adressage, même couche applicative, modèle d'exploitation opposé : Talos est immuable,
> sans SSH ni gestionnaire de paquets, et se pilote entièrement par API. Ici tu as une
> distribution normale et tu conduis `kubeadm` toi-même : plus de pièces mobiles, et c'est ce qui
> rend le lab intéressant à lire.

---

## 🧰 1. Prérequis (sur l'hôte)

| Outil | Rôle | Installation |
|---|---|---|
| VirtualBox 7 | hyperviseur | https://www.virtualbox.org/ |
| Vagrant | création des VM | https://developer.hashicorp.com/vagrant |
| `git` | le dépôt **et son sous-module `_k8s/`** | https://git-scm.com/ |
| `kubectl` | utiliser le cluster | https://kubernetes.io/docs/tasks/tools/ |
| `helm` | addons `_k8s/` | https://helm.sh/docs/intro/install/ |
| `uv` *(optionnel)* | `make docs` | https://docs.astral.sh/uv/ |

C'est toute la liste — aucun binaire propre au cluster sur ta machine. `kubeadm`, `kubelet`,
`kubectl` et `containerd` vivent *dans* les VM, installés par
[`kubeadm/provision.sh`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/provision.sh)
pendant `vagrant up`. La box `bento/debian-13` est téléchargée par Vagrant au premier usage ;
aucun plugin nécessaire.

Gérer le sous-module :

```bash
git submodule update --init --recursive     # remplit _k8s/ sur un clone existant
git submodule update --remote _k8s          # le déplace sur le dernier commit amont
```

> ⚠️ **`git pull` ne met pas le sous-module à jour.** Il ne déplace que *ce* dépôt, `_k8s/` reste
> sur le commit épinglé avant — tu exécuterais les commandes documentées contre une couche
> applicative plus ancienne. Un `git status` qui affiche `modified: _k8s (new commits)` signifie
> juste que le checkout ne correspond plus à l'épingle.

> ⚠️ **VirtualBox et KVM ne peuvent pas partager VT-x.** Module KVM chargé, `vagrant up` meurt sur
> `VERR_VMX_IN_VMX_ROOT_MODE`. Décharge-le d'abord (`sudo modprobe -r kvm_intel kvm`, ou
> `kvm_amd`) — voir [`DEPANNAGE.md`](DEPANNAGE.md).

> 💡 Garde le `kubectl` de l'hôte à un minor près du cluster (1.35 → 1.37 pour un cluster 1.36),
> ou rabats-toi sur celui de la VM : `vagrant ssh k8s-cp1 -c 'kubectl get nodes -o wide'`.

---

## 🗺️ 2. Plan d'adressage (réseau host-only `192.168.56.0/24`)

| Élément | IP |
|---|---|
| Hôte (passerelle host-only) | `192.168.56.1` |
| Serveur DHCP VirtualBox | `192.168.56.2` |
| **VIP de l'API Kubernetes** (keepalived) | **`192.168.56.5`** |
| `k8s-cp1` / `cp2` / `cp3` | `192.168.56.10` / `.20` / `.30` |
| `k8s-w1` / `w2` / `w3` … | `192.168.56.101` / `.102` / `.103` … |
| DHCP host-only par défaut de VirtualBox (réservé) | `192.168.56.100` |
| Plage LoadBalancer (annonce L2 Cilium) | `192.168.56.200` – `.230` |
| **IP du Gateway Envoy** (cible du DNS wildcard) | `192.168.56.200` — la 1re de la plage |

Réseau des pods `10.244.0.0/16`, réseau des Services `10.96.0.0/12`. Les IP des nodes sont
**statiques**, posées par le `Vagrantfile` ; il refuse une IP de node qui tombe sur `.1`, `.2`,
`.100` ou sur la VIP, et refuse les doublons.

Chaque VM a **2 cartes** : NIC1 = NAT VirtualBox (Internet, `10.0.2.15` sur *toutes* les VM) et
NIC2 = host-only `192.168.56.x` (cluster, API, etcd, pods). La route par défaut passe par le NAT
pour que les VM atteignent `apt` et les registres ; ce qui doit être host-only, c'est l'*identité*
du node, jamais sa route par défaut — voir `node-ip` au §8.

> ℹ️ **Le nom de l'interface host-only n'est jamais codé en dur.** Debian 13 la nomme
> habituellement `enp0s8`, certaines box donnent encore `eth1`. `provision.sh` trouve l'interface
> qui porte l'IP du node, l'écrit dans `/etc/kubeadm-lab/node.env`, et `cluster-up.sh` la recopie
> dans `_out/cluster.env` sous `HOSTONLY_IF`. keepalived y attache VRRP et Cilium y annonce les IP
> de LoadBalancer.

> ℹ️ La résolution de noms ne dépend ni du DNS ni de l'ordre de démarrage : le `Vagrantfile`
> pousse un bloc `/etc/hosts` identique sur chaque node, et `provision.sh` supprime la ligne
> `127.0.1.1 <hostname>` de Debian — laissée en place, le kubelet résout son propre nom en
> loopback et le node s'enregistre comme injoignable.

---

## ⚙️ 3. Choisir la topologie — `lab.env`

`lab.env` est la source unique lue par le `Vagrantfile`, par `kubeadm/cluster-up.sh` et par les
scripts `_k8s/*-up.sh`. Copie le modèle versionné (`lab.env` est gitignoré) :

```bash
cp lab.env.example lab.env
```

Le format est strict : un `KEY=value` par ligne, pas d'espace autour du `=`. Une vraie variable
d'environnement gagne toujours, ce qui rend les surcharges ponctuelles possibles :
`WORKERS=5 vagrant up`.

| Variable | Défaut | Rôle |
|---|---|---|
| `K8S_VERSION` | `1.36.3` | version installée (`kubelet`/`kubeadm`/`kubectl`, épinglée puis `apt-mark hold`) |
| `K8S_APT_MINOR` | `v1.36` | minor du dépôt `pkgs.k8s.io` — **doit correspondre à `K8S_VERSION`** |
| `CONTAINERD_SOURCE` | `docker` | `docker` → containerd 2.x · `debian` → containerd 1.7 (§8) |
| `SYSTEM_UPGRADE` | `true` | `apt-get upgrade` complet par VM ; `false` divise `vagrant up` par ~2 |
| `REGISTRY_MIRROR` | *(vide)* | miroir pull-through → `/etc/containerd/certs.d/docker.io/hosts.toml` |
| `CONTROL_PLANES` | `1` | `1` = simple, `3` = HA. **Les nombres pairs sont refusés** |
| `WORKERS` | `2` | nombre de workers ; `0` est valide (voir `UNTAINT_CP`) |
| `CP_MEM` / `CP_CPU` | `3072` / `2` | ressources control plane — **jamais sous `3072`** : etcd |
| `WK_MEM` / `WK_CPU` | `2048` / `2` | ressources worker |
| `BOX` | `bento/debian-13` | le lab est écrit et testé pour Debian 13 |
| `NODE_PREFIX` | `k8s` | noms des VM/nodes : `k8s-cp1`, `k8s-w1`… |
| `CLUSTER_NAME` | `kubeadm-lab` | `clusterName` kubeadm + contexte du kubeconfig |
| `NETWORK` | `192.168.56` | réseau host-only (3 premiers octets) |
| `VIP` | `192.168.56.5` | VIP de l'API = `controlPlaneEndpoint`, portée par keepalived |
| `CP_IP_START` / `CP_IP_STEP` | `10` / `10` | → `.10`, `.20`, `.30` |
| `WK_IP_START` / `WK_IP_STEP` | `101` / `1` | → `.101`, `.102`, `.103` |
| `POD_CIDR` | `10.244.0.0/16` | `podSubnet` kubeadm — **le CNI doit annoncer le même** |
| `SERVICE_CIDR` | `10.96.0.0/12` | `serviceSubnet` kubeadm |
| `LB_POOL_START` / `LB_POOL_END` | `192.168.56.200` / `.230` | plage `LoadBalancer` ; **la 1re est celle du Gateway** |
| `VRRP_ROUTER_ID` | `51` | groupe VRRP keepalived (1-255) — à changer pour coexister avec un autre lab keepalived |
| `CNI` | `cilium` | `cilium`, `calico`, `flannel` ou `none` (§9) |
| `CILIUM_VERSION` | `1.20.0` | version du chart Cilium (ignorée hors `CNI=cilium`) |
| `KUBE_PROXY_REPLACEMENT` | `true` | remplacement eBPF de kube-proxy — **exige `CNI=cilium`** |
| `UNTAINT_CP` | `auto` | retirer le taint control-plane : `auto` (seulement si `WORKERS=0`), `true`, `false` |
| `LAB_DOMAIN` | `kubeadm.lab.example.io` | domaine des UI (`*.<domaine>` : TLS wildcard + `HTTPRoute`) |
| `SELF_SIGNED` | `true` | `true` = wildcard signé par une AC locale (`openssl`) · `false` = cert-manager + Let's Encrypt |
| `LAB_DNS_ZONE` | *(vide → 2 derniers labels)* | zone DNS du solveur ACME DNS-01 — `SELF_SIGNED=false` seulement |
| `LAB_ACME_EMAIL` | *(vide → `admin@<zone>`)* | compte Let's Encrypt — `SELF_SIGNED=false` seulement |
| `LAB_ACME_ISSUER` | `staging` | `staging` (non fiable, quota énorme) ou `prod` (fiable, **5 certificats/semaine**) |
| `CLOUDFLARE_API_TOKEN` | *(vide)* | DNS-01 cert-manager — `SELF_SIGNED=false` seulement, et **jamais** dans le modèle |

Deux autres sont lues par `cluster-up.sh` sans figurer dans le modèle : `OUT` (`_out`) et
`WAIT_API` (`600`, secondes d'attente de l'apiserver sur la VIP).

**Ce que coûte chaque topologie.** Par défaut (1 CP + 2 workers) : **7 Go de RAM**, 6 vCPU. HA
complète (`CONTROL_PLANES=3`, `WORKERS=3`) : 3 × 3072 + 3 × 2048 = **15,4 Go**, 12 vCPU. Les
disques sont des clones liés, donc la box est stockée à peu près une fois.

Trois contraintes à connaître avant d'éditer :

- **Les control planes doivent être en nombre impair** — le `Vagrantfile` et `cluster-up.sh`
  refusent tous les deux un nombre pair. etcd tient son quorum à `(n/2)+1` : 2 membres coûtent
  deux fois un CP et ne tolèrent aucune panne.
- **`CP_MEM` ≥ 3072.** Le preflight de kubeadm exige ~1700 Mio : 2048 passe, puis affame l'etcd
  empilé dès que les addons s'accumulent. `_k8s/observability/` demande `4096`.
- **`K8S_VERSION` et `K8S_APT_MINOR` doivent concorder.** Les dépôts `pkgs.k8s.io` sont par
  minor, et l'écart échoue dans `apt` sur une erreur qui ne le mentionne jamais. C'est cette
  paire qu'on incrémente pour une montée de version —
  [`kubeadm/MISE-A-JOUR.md`](kubeadm/MISE-A-JOUR.md).

---

## 🚀 4. Démarrer le cluster

```bash
vagrant up                      # VM + paquets + containerd + kubeadm + keepalived
./kubeadm/cluster-up.sh         # init + jonctions + kubeconfig
```

**`vagrant up` ne bootstrape rien.** Il crée les VM et exécute `provision.sh` dans chacune, qui
pose, dans l'ordre : `/etc/hosts` · swap coupé + modules noyau + sysctl · paquets de base
(`conntrack`, `socat`, `ethtool`, `open-iscsi`, `nfs-common`…) · containerd avec
`SystemdCgroup = true` · `kubelet`/`kubeadm`/`kubectl` épinglés et gelés · **images pré-tirées** ·
et, sur les control planes, **keepalived portant la VIP**. Chaque VM finit prête à recevoir un
`kubeadm init` ou `join`, rien de plus.

`cluster-up.sh` affiche ensuite cinq étapes :

| Étape | Ce qui se passe |
|---|---|
| `[1/5]` | rend les configs kubeadm dans `_out/` **sur l'hôte**, depuis [`kubeadm/templates/`](https://github.com/OPS-NC/Vagrant-kubeadm/tree/main/kubeadm/templates) |
| `[2/5]` | `kubeadm init` sur le 1er CP ; copie `admin.conf` vers `./kubeconfig` ; **attend `https://<VIP>:6443/readyz`** |
| `[3/5]` | joint les control planes secondaires, **un par un** (etcd n'accepte qu'un changement d'appartenance à la fois) |
| `[4/5]` | joint les workers |
| `[5/5]` | retire le taint selon `UNTAINT_CP`, étiquette les workers, écrit `_out/cluster.env` (`HOSTONLY_IF` détecté inclus) |

Avant de toucher à quoi que ce soit, il valide la config et vérifie que **toutes** les VM
attendues sont `running` — une seconde en amont, contre un `vagrant ssh` qui expire au milieu
d'un `join`.

```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide
```

Le kubeconfig ne demande aucune retouche : son `server:` est la VIP, joignable depuis l'hôte.

> ⚠️ **Les nodes seront `NotReady`, et c'est normal.** kubeadm n'installe jamais de CNI. Sans
> réseau de pods, le kubelet signale `cni plugin not initialized`, CoreDNS reste `Pending` et les
> nodes restent `NotReady`. Le remède est la commande suivante : `./_k8s/platform-up.sh` (§6).

> 💡 **`cluster-up.sh` est idempotent** — `node-init.sh` refuse de rejouer `kubeadm init` si
> `/etc/kubernetes/admin.conf` existe, `node-join.sh` saute un node qui a déjà `kubelet.conf`.
> Le relancer est aussi la manière d'agrandir le lab (§7.1). Les identifiants de jonction sont
> régénérés à **chaque** exécution, parce que le token expire au bout de 24 h et la clé de
> certificats au bout de 2 h — un lancement trois jours plus tard fonctionne donc directement.

Pour une autre topologie, édite `lab.env`, ou surcharge sur place **pour les deux commandes**,
chacune relisant son propre environnement :

```bash
CONTROL_PLANES=3 WORKERS=3 vagrant up
CONTROL_PLANES=3 WORKERS=3 ./kubeadm/cluster-up.sh
```

---

## 🎓 5. Faire la même chose à la main

C'est la raison d'être du lab. Les scripts existent pour ne pas retaper ces commandes à chaque
reconstruction, pas pour les cacher. Voici le même parcours à la main, sur un lab déjà
`vagrant up`.

### 5.1 Ce que `vagrant up` t'a déjà laissé

```bash
vagrant ssh k8s-cp1
sudo -i
kubeadm version -o short                 # v1.36.3, gelé par apt-mark
containerd --version                     # 2.x quand CONTAINERD_SOURCE=docker
crictl ps                                # parle à /run/containerd/containerd.sock
ip -4 addr show | grep 192.168.56.5      # la VIP est DÉJÀ là, avant tout init
cat /etc/kubeadm-lab/node.env            # NODE_IP, HOSTONLY_IF, VIP…
```

La VIP debout **avant** `kubeadm init` est toute la raison pour laquelle keepalived est utilisé
ici plutôt que kube-vip (§8.1).

### 5.2 `kubeadm init` sur le premier control plane

La façon du dépôt — `cluster-up.sh` a déjà rendu la config dans `_out/`, visible depuis la VM par
le dossier synchronisé :

```bash
sudo kubeadm init --config /vagrant/_out/kubeadm-init.yaml --upload-certs \
     --skip-phases=addon/kube-proxy          # seulement si KUBE_PROXY_REPLACEMENT=true
```

L'équivalent en options seules, pour le voir sans fichier de config :

```bash
sudo kubeadm init \
  --control-plane-endpoint 192.168.56.5:6443 \
  --apiserver-advertise-address 192.168.56.10 \
  --pod-network-cidr 10.244.0.0/16 \
  --service-cidr 10.96.0.0/12 \
  --cri-socket unix:///run/containerd/containerd.sock \
  --apiserver-cert-extra-sans 192.168.56.5,192.168.56.10,192.168.56.20,192.168.56.30 \
  --upload-certs \
  --skip-phases=addon/kube-proxy
```

Les deux adresses ne sont pas la même chose : `--apiserver-advertise-address` est l'IP *réelle*
sur laquelle cet apiserver écoute, `--control-plane-endpoint` est la VIP *partagée* gravée dans
les certificats et dans chaque kubeconfig.

> ⚠️ **La forme en options ne peut pas poser `node-ip`, d'où le `--config` du dépôt.** Avec les
> seules options, le kubelet prend l'interface de la route par défaut — le NAT, `10.0.2.15`,
> **identique sur toutes les VM**. Tous les nodes s'enregistrent alors avec la même adresse :
> `kubectl get nodes -o wide` paraît crédible pendant que les logs, `exec`, les sondes et le
> trafic inter-nodes partent au mauvais endroit. Le réglage n'existe que sous
> `nodeRegistration.kubeletExtraArgs`.

Deux autres choses irréparables après coup : **`--upload-certs`** stocke les AC du cluster dans
le Secret `kubeadm-certs` (sans lui, un second control plane ne peut joindre qu'après une copie
manuelle de `/etc/kubernetes/pki`), et les **certSANs**, qui exigent de régénérer le certificat
de l'API pour changer — d'où les 5 IP de control plane déclarées d'emblée, y compris pour des
nodes qui n'existent pas encore.

### 5.3 Joindre des nodes

```bash
# sur le control plane — imprime une commande prête à coller, token valable 24 h
sudo kubeadm token create --print-join-command
# sur le worker
sudo kubeadm join 192.168.56.5:6443 --token <t> --discovery-token-ca-cert-hash sha256:<h>
```

Un second control plane demande deux ingrédients de plus : `--control-plane` et la **clé de
certificats**, qui déchiffre le Secret `kubeadm-certs`.

```bash
# sur cp1 — rechiffre le Secret et imprime une NOUVELLE clé en dernière ligne
sudo kubeadm token create --print-join-command \
  --certificate-key "$(sudo kubeadm init phase upload-certs --upload-certs | tail -n1)"
```

Quatre choses mordent ici :

- **Cette ligne de jonction imprimée est précisément ce que le lab n'utilise *pas*.** Elle ne peut
  pas porter `node-ip` (§5.2), donc un node joint comme ça s'enregistre avec `10.0.2.15`. Le dépôt
  rend un fichier `JoinConfiguration` à la place et lance
  `kubeadm join --config /vagrant/_out/join-<node>.yaml`. Tous les nodes avec la même
  `INTERNAL-IP`, c'est ça, chaque fois.
- **La clé de certificats expire au bout de 2 heures**, le token au bout de 24. Les deux se
  régénèrent pour rien ; une clé périmée donne une erreur de déchiffrement qui ne parle jamais
  d'expiration.
- **`--config` et `--certificate-key` sont mutuellement exclusifs.** Avec un fichier de config, la
  clé va sous `controlPlane.certificateKey` — *pas* à la racine du document, contrairement à
  `InitConfiguration`.
- **Joins les control planes un par un.** Chaque jonction ajoute un membre etcd, et etcd n'accepte
  qu'un changement d'appartenance à la fois ; deux en parallèle échouent sur une erreur de quorum
  illisible.

Récupérer un kubeconfig ne demande aucun `scp` — le dossier synchronisé est là, et `server:` pointe
déjà la VIP :

```bash
vagrant ssh k8s-cp1 -c 'sudo cat /etc/kubernetes/admin.conf' > kubeconfig
chmod 0600 kubeconfig && export KUBECONFIG="$PWD/kubeconfig"
```

---

## 📦 6. La suite : la couche applicative

Un cluster nu ne sert à rien — ici il n'est même pas `Ready`. Cilium, Envoy Gateway,
cert-manager, metrics-server, Longhorn, Vault, CloudNativePG, Prometheus/Loki, Kyverno, Trivy,
MinIO, Argo CD… viennent tous de
[k8s-playground](https://github.com/OPS-NC/k8s-playground), monté ici en `_k8s/` et partagé avec
le jumeau Talos. Sa documentation est publiée à part :
**<https://ops-nc.github.io/k8s-playground/>**.

```bash
./_k8s/platform-up.sh                       # CNI → Envoy Gateway → metrics-server → TLS
./_k8s/install.sh longhorn vault argocd     # addons opt-in
./_k8s/install.sh list                      # le catalogue complet
./_k8s/install.sh all                       # plateforme + tous les addons, dans l'ordre
./_k8s/longhorn/longhorn-up.sh              # un addon seul
```

Rien à déclarer : le **lab** est le dossier contenant `_k8s/` qui porte le `Vagrantfile` (donc
`lab.env`, `_out/` et `kubeconfig` s'y trouvent), et la **distribution** se lit sur son contenu —
un `kubeadm/cluster-up.sh` à côté du `Vagrantfile` signifie le lab kubeadm. Ça marche dès le
clone, avant tout `vagrant up`. Un `./_k8s/install.sh kubeadm platform` explicite,
`--distro=kubeadm` ou `K8S_DISTRO` gagnent toujours, et `LAB_DIR` est la porte de sortie pour une
arborescence inhabituelle — aucun des deux n'est nécessaire ici.

`platform-up.sh` installe le CNI en premier ; les nodes passent `Ready` une à deux minutes après.

> ⚠️ **Cette couche suppose `CNI=cilium`** (le défaut). Elle a besoin d'un Service
> `LoadBalancer` qui obtienne réellement une IP, ce que seule l'annonce L2/ARP de Cilium fournit
> sur un réseau host-only — sinon le Gateway reste en `EXTERNAL-IP <pending>` et aucune UI n'est
> joignable. Voir §9.

### 6.1 Les deux prérequis manuels

Rien dans le cluster ne peut les faire à ta place.

**a) Faire résoudre `*.<LAB_DOMAIN>` vers l'IP du Gateway.** Toutes les UI du lab passent par le
Service `LoadBalancer` d'Envoy, qui prend la première IP de `LB_POOL_START` — `192.168.56.200` par
défaut. Avec `SELF_SIGNED=true`, une ligne `/etc/hosts` suffit et aucun enregistrement public
n'est nécessaire :

```bash
kubectl -n envoy-gateway-system get svc -o wide | grep LoadBalancer   # l'IP réelle
# /etc/hosts
# 192.168.56.200  argo.kubeadm.lab.example.io grafana.kubeadm.lab.example.io
```

Avec `SELF_SIGNED=false`, il faut un vrai enregistrement `A` wildcard `*.<LAB_DOMAIN>` → l'IP du
Gateway, en **DNS-only** (un proxy CDN ne peut pas joindre une origine privée `192.168.56.x`).

**b) Choisir le mode TLS** avec `SELF_SIGNED`. `true` : `platform-up.sh` fabrique une AC locale et
un wildcard avec `openssl` — pas de cert-manager, pas de token, pas de domaine public, et un
avertissement du navigateur jusqu'à l'import de `_out/self-signed/ca.crt`. `false` : cert-manager
+ Let's Encrypt en ACME DNS-01, ce qui demande un vrai domaine, `CLOUDFLARE_API_TOKEN`, et le
respect du quota de production de **5 certificats par semaine** (`LAB_ACME_ISSUER=staging` est le
défaut pour cette raison). Les deux chemins remplissent le même Secret
`wildcard-<LAB_DOMAIN avec tirets>-tls`, donc aucun addon n'a à savoir lequel tu as choisi.

---

## ♻️ 7. Cycle de vie

```bash
vagrant status                 # état des VM
vagrant halt                   # extinction (le cluster revient au `up` suivant)
vagrant up                     # rallumage
vagrant destroy -f             # supprime toutes les VM
rm -rf _out kubeconfig         # nettoyer l'état côté hôte avant de reconstruire
```

Garder le dépôt à jour prend **deux** commandes, `git pull` laissant `_k8s/` où il était :

```bash
git pull
git submodule update --init --recursive   # _k8s/ revient sur le commit épinglé ici
git submodule update --remote _k8s        # ou : sauter au dernier k8s-playground
```

### 7.1 Agrandir le lab

L'idempotence de `cluster-up.sh` *est* la procédure :

1. augmente `WORKERS` (ou `CONTROL_PLANES`, en restant impair) dans `lab.env` ;
2. `vagrant up` — seules les nouvelles VM sont créées et provisionnées ;
3. `./kubeadm/cluster-up.sh` — saute ce qui est en place, joint les nouveaux nodes avec des
   identifiants frais.

Aucune régénération de certificat : les `certSANs` couvrent déjà 5 IP de control plane (§5.2).

Retirer un worker — vidange d'abord, pour que le cluster arrête de placer des pods sur une machine
qui va disparaître :

```bash
kubectl drain k8s-w3 --ignore-daemonsets --delete-emptydir-data
vagrant destroy -f k8s-w3
kubectl delete node k8s-w3
```
puis baisse `WORKERS` dans `lab.env`.

### 7.2 Défaire le cluster sans détruire les VM

```bash
./kubeadm/cluster-reset.sh          # demande confirmation
./kubeadm/cluster-reset.sh --yes    # sans interaction
```

Il lance `kubeadm reset` sur chaque node (**les workers d'abord**, pour qu'ils se désinscrivent
pendant que l'API répond encore), puis supprime `_out/` et `kubeconfig`. Les VM gardent leurs
paquets, containerd et keepalived, donc la reconstruction se réduit à
`./kubeadm/cluster-up.sh` — des minutes au lieu d'un `vagrant up` complet. À préférer à
`vagrant destroy` pour rejouer un bootstrap échoué, ou pour changer `POD_CIDR`, `SERVICE_CIDR`, le
CNI ou la VIP : les quatre sont figés à `kubeadm init`.

> ⚠️ **Destructif** : etcd, les certificats et toutes les charges de travail sont perdus, y
> compris les PersistentVolumes sur disque de node.

> ℹ️ **Pourquoi un reset dédié.** `kubeadm reset` laisse volontairement ce qu'il n'a pas créé —
> interfaces CNI, programmes eBPF **épinglés sous `/sys/fs/bpf`** (qui survivent au DaemonSet et
> continuent d'intercepter le trafic d'un cluster qui n'existe plus), et règles iptables de
> kube-proxy. `node-reset.sh` nettoie tout ça ; sans cette passe, l'`init` suivant hérite d'un
> datapath fantôme et le réseau de pods déraille sans que rien n'apparaisse dans les logs.

---

## 🔍 8. Notes de conception

### 8.1 La VIP est portée par keepalived, pas par kube-vip

La décision la plus structurante du dépôt. `controlPlaneEndpoint` pointe la VIP et est **gravé
dans les certificats et dans chaque kubeconfig au moment du `kubeadm init`** : la VIP doit donc
exister *avant* l'init.

kube-vip, la réponse habituelle des guides HA kubeadm, tourne en pod statique et élit son leader
**à travers l'API Kubernetes** — c'est-à-dire à travers la VIP même qu'il est censé porter. La
sortie documentée est `--k8sConfigPath /etc/kubernetes/super-admin.conf`, elle-même fragile depuis
que Kubernetes 1.29 a sorti `admin.conf` du groupe `system:masters`
([kube-vip#684](https://github.com/kube-vip/kube-vip/issues/684), toujours ouverte).

keepalived n'a rien de tout ça : un simple démon VRRP, qui ignore Kubernetes et lève la VIP au
démarrage de la VM. `provision.sh` le configure en **VRRP unicast** (le multicast est la première
chose à mal se comporter sur un switch host-only VirtualBox, et on connaît de toute façon toutes
les IP de control plane), avec les priorités cp1 = 100 / cp2 = 90 / cp3 = 80 et un `vrrp_script`
qui interroge `https://127.0.0.1:6443/livez/ping` toutes les 3 s avec `weight -30` — un CP dont
l'apiserver est mort tombe à 70 et un cp2 sain à 90 reprend la VIP. `/livez/ping` est lisible
anonymement grâce au binding `system:public-info-viewer` créé par kubeadm, donc aucun identifiant
n'a besoin d'atteindre un script de santé. Il n'y a aucun bloc `authentication` : VRRPv2 envoie son
mot de passe en clair et n'apporte rien ici, la frontière de confiance étant le réseau host-only —
`VRRP_ROUTER_ID` est le bouton pour coexister avec un autre lab keepalived.

Tant qu'aucun cluster n'existe, le contrôle échoue sur chaque CP : tous perdent 30 points, l'ordre
relatif tient, et la VIP est portée quand même — ce dont `kubeadm init` a besoin. kube-vip reste
une bonne option *une fois le cluster debout* (mode `--services`) ; c'est le rôle au bootstrap qui
ne marche pas ici.

La VIP est utilisée **même avec un seul control plane**, pour la même raison : pointer
`controlPlaneEndpoint` sur l'IP réelle de cp1 transformerait « 1 CP → 3 CP » en régénération de
tous les certificats et redistribution de tous les kubeconfig, au lieu d'un simple `join`.

### 8.2 containerd 2.x depuis le dépôt Docker

Debian 13 livre containerd **1.7.24**. Seule la branche 2.x implémente la méthode CRI
`RuntimeConfig` que kubeadm utilise pour lire le pilote cgroup du runtime. En 1.36 son absence est
un **avertissement** de preflight ; le repli disparaît en **1.37**, et le backport vers 1.7 a été
**refusé** ([containerd#11346](https://github.com/containerd/containerd/issues/11346), fermée sans
merge). `CONTAINERD_SOURCE=debian` reste disponible pour un lab hors-ligne, et c'est une impasse
pour les montées de version.

`SystemdCgroup = true` compte plus que le champ `cgroupDriver` du kubelet : Debian 13 est en
cgroup v2 avec systemd comme gestionnaire, et laisser containerd en `cgroupfs` met deux
gestionnaires sur la même hiérarchie — les nodes deviennent instables sous charge.

> ⚠️ **Le piège 1.7 → 2.x** : la clé de l'image `pause` a changé de *nom et d'emplacement*. La
> config v2 a `sandbox_image` sous `[plugins."io.containerd.grpc.v1.cri"]` ; la v3 a `sandbox`
> sous `[plugins.'io.containerd.cri.v1.images'.pinned_images]`. Une config recopiée telle quelle
> perd le réglage en silence, donc `provision.sh` la régénère depuis
> `containerd config default` à chaque passage et corrige la clé présente. Le tag lui-même vient
> de `kubeadm config images list`, jamais codé en dur : un écart est invisible en ligne et fatal
> hors-ligne.

### 8.3 API kubeadm `v1beta4`

Défaut depuis Kubernetes 1.31 ; `v1beta3` est déprécié. Le changement cassant à connaître :
`extraArgs` et `kubeletExtraArgs` ne sont plus des **dictionnaires** mais des **listes de
`{name, value}`**, pour qu'une option puisse être répétée. Tout fichier écrit avant 1.31 est
invalide tel quel, et l'erreur de kubeadm ne désigne pas la forme.

```yaml
# v1beta3 :  extraArgs: {bind-address: "0.0.0.0"}
# v1beta4 :  extraArgs: [{name: bind-address, value: "0.0.0.0"}]
```

`make validate-kubeadm` attrape exactement ça, en CI, sans cluster.

### 8.4 Ce que kubeadm ne fait pas, et que `cluster-up.sh` rattrape

- **Les étiquettes de rôle des workers** — kubeadm n'en pose aucune, donc `kubectl get nodes`
  affiche `<none>` et les sélecteurs `node-role.kubernetes.io/worker` ne correspondent à rien.
- **Le taint control-plane** : `UNTAINT_CP=auto` ne le retire que si `WORKERS=0`, ce qui rend un lab
  à 1 VM utilisable.
- **Les métriques du control plane** : `bind-address: 0.0.0.0` sur `controllerManager` et
  `scheduler`, qui sinon n'écoutent qu'en loopback et donnent à Prometheus deux cibles DOWN sans
  explication.
- **Les images pré-tirées**, pendant `vagrant up` et en parallèle entre VM, pour que `kubeadm init`
  ne télécharge rien — la première cause de timeout au bootstrap. Les workers ne tirent que `pause`
  et `kube-proxy`, ~500 Mio économisés chacun.
- **Le swap** coupé et masqué, unités systemd de swap incluses (`/etc/fstab` ne les décrit pas).

Le dossier synchronisé `/vagrant` est un **rouage**, pas un confort : `cluster-up.sh` rend les
configs sur l'hôte et les VM les lisent dans `/vagrant/_out/`, donc rien n'a besoin de `scp` et
aucun secret ne passe en ligne de commande où il finirait dans l'historique du shell.
`_out/join.env` contient bien le token de jonction et la clé de certificats, lisibles depuis toutes
les VM — acceptable pour un lab, pas un modèle pour la production.

---

## 🌐 9. CNI : Cilium, Calico ou Flannel

**kubeadm n'installe jamais de CNI.** Contrairement au jumeau Talos — où flannel peut être posé
par l'OS au bootstrap — le réseau de pods est ici *toujours* installé après, par
`./_k8s/platform-up.sh`. `CNI` est lu par `cluster-up.sh` (pour la décision kube-proxy et
`_out/cluster.env`) et par l'étape plateforme (quel chart installer).

| `CNI=` | IP de `LoadBalancer` | Couche `_k8s/` utilisable |
|---|---|---|
| **`cilium`** *(défaut)* | ✅ pool + annonce L2/ARP | ✅ oui |
| `calico` | ❌ BGP seulement | ⚠️ exige MetalLB par-dessus |
| `flannel` | ❌ | ❌ non |
| `none` | ❌ | dépend de ce que tu installes |

**En pratique : garde `cilium`.** C'est la seule valeur qui donne une `EXTERNAL-IP` aux Services
sur un réseau host-only, donc la seule qui te donne les UI HTTPS. `calico` est là pour comparer
les CNI et travailler sur `NetworkPolicy`
([sa page](https://github.com/OPS-NC/k8s-playground/blob/main/calico/LISEZ-MOI.md)) ; `flannel`
pour un cluster délibérément nu.

> ⚠️ **`KUBE_PROXY_REPLACEMENT=true` exige `CNI=cilium`**, et `cluster-up.sh` refuse toute autre
> combinaison. Avec `--skip-phases=addon/kube-proxy` et sans remplacement, **aucune ClusterIP ne
> répond** — pas même CoreDNS joignant l'API. Le message d'erreur donne les deux sorties :
> `CNI=cilium`, ou `KUBE_PROXY_REPLACEMENT=false`.

> ℹ️ Cilium a besoin de `k8sServiceHost`/`k8sServicePort` quand kube-proxy disparaît : plus rien
> ne provisionne la ClusterIP de l'apiserver, donc l'agent ne peut pas s'amorcer par
> `kubernetes.default`. Le lab le pointe sur la **VIP**, ce qui fait aussi survivre les agents à
> la perte d'un control plane.

> ⚠️ **`POD_CIDR` doit être le CIDR que le CNI annonce vraiment.** Cilium en mode `cluster-pool`
> vaut `10.0.0.0/8` par défaut, sans rapport avec ce qu'on a dit à kubeadm ; `cilium-up.sh` lui
> repasse `POD_CIDR` explicitement. Deux valeurs divergentes donnent un réseau de pods cassé qui
> a l'air configuré.

> ⚠️ **Changer de CNI sur un cluster vivant n'est pas supporté.** `./kubeadm/cluster-reset.sh`
> (ou `vagrant destroy`) d'abord : deux CNI se disputent le réseau de pods, et le datapath
> résiduel est exactement ce que `node-reset.sh` existe pour nettoyer.

---

## 🛠️ 10. Valider une modification

Tout se valide **sans démarrer de cluster** :

```bash
make validate       # shell + YAML + Vagrantfile + templates kubeadm + liens de doc
make docs           # régénère docs/index.html depuis tous les README (EN + FR)
make help           # liste les cibles
```

| Cible | Ce qu'elle couvre |
|---|---|
| `validate-shell` | `bash -n` sur chaque `*.sh` suivi par git |
| `validate-yaml` | parse chaque `*.yaml` / `*.yml` suivi par git (PyYAML, récupéré par `uv`) |
| `validate-vagrant` | `vagrant validate` ; en local, vérifie aussi la config du provider |
| `validate-defaults` | vérifie que les défauts de repli du `Vagrantfile` et de `cluster-up.sh` correspondent encore à `lab.env.example`, clé par clé |
| `validate-kubeadm` | rend les 3 templates avec des valeurs bidon dans un dossier jetable, les parse, puis lance `kubeadm config validate` **si `kubeadm` est dans le PATH** |
| `validate-docs` | construit la doc dans un fichier jetable et échoue sur tout lien `*.md` mort ou ancre inconnue |

`validate-kubeadm` justifie son existence : elle attrape une vraie erreur de schéma v1beta4 au
lieu de te la faire découvrir dix minutes après le début d'un `vagrant up`. En CI, où `kubeadm`
est installé, le contrôle de schéma tourne toujours.

Le workflow `ci` appelle ces mêmes cibles `make` à chaque pull request, donc un contrôle ne peut
pas passer en CI et échouer chez toi. Il vérifie aussi que les garde-fous se déclenchent
réellement — `CONTROL_PLANES=2 vagrant validate` **doit** être rejeté. Rien dans le `Makefile` ne
touche un cluster vivant ni ne régénère de secret : `make validate` est sans risque sur un lab
debout.

> ℹ️ `validate-shell` et `validate-yaml` ne couvrent que les fichiers suivis par **ce** dépôt. Le
> sous-module `_k8s/` est un pointeur unique, donc aucun de ses scripts n'est vérifié ici — ils le
> sont dans la CI de k8s-playground.

---

## 📄 11. Licence

**Apache License 2.0** — voir
[`LICENSE`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/LICENSE). Utilise-le, modifie-le,
redistribue-le, y compris commercialement, tant que tu conserves la notice de copyright et que tu
signales tes modifications. **Aucune garantie** : c'est un lab, pas de production.

Elle couvre ce que ce dépôt contient — le `Vagrantfile`, les scripts `kubeadm/`, les templates,
les manifestes, la doc. Elle ne s'étend pas aux composants tiers que ces scripts téléchargent
(Kubernetes, containerd, keepalived, Cilium, Envoy Gateway, Longhorn, Vault…), ni au sous-module
`_k8s/` : [k8s-playground](https://github.com/OPS-NC/k8s-playground) porte sa propre `LICENSE`.
