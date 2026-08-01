<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🏠 ☸️ Vagrant-KubeADM

> Monte un **cluster Kubernetes 1.36 à la main — avec `kubeadm`, sur Debian 13** dans des VM
> **VirtualBox**. `vagrant up` prépare les machines, un script enchaîne les commandes
> `kubeadm`, et une couche applicative complète (Cilium, Envoy Gateway, Longhorn, Vault,
> PostgreSQL…) vient par-dessus. Control plane unique ou **HA à 3 CP derrière une VIP
> keepalived**.

Ce lab n'est volontairement **pas** un installeur clé en main. Chaque VM est une Debian
ordinaire, avec SSH et `apt` ; chaque étape des scripts est une commande `kubeadm` que tu
pourrais taper toi-même, et §5 montre exactement lesquelles. Ce que le dépôt apporte, c'est la
partie ingrate : la VIP qui doit exister *avant* le `kubeadm init`, le `node-ip` que tout lab
Vagrant rate, la configuration containerd 2.x, les SAN de certificat qu'on ne peut plus
ajouter après coup.

**Le parcours complet, en quatre étapes :**

```bash
git clone --recurse-submodules https://github.com/OPS-NC/Vagrant-kubeadm.git
cd Vagrant-kubeadm
cp lab.env.example lab.env      # choisir la topologie
vagrant up                      # crée et PRÉPARE les VM (aucun cluster monté)
./kubeadm/cluster-up.sh         # kubeadm init + join + kubeconfig
export KUBECONFIG="$PWD/kubeconfig" LAB_DIR="$PWD"
./_k8s/install.sh kubeadm platform   # CNI, Envoy Gateway, metrics-server, TLS wildcard
```

| | |
|---|---|
| 📖 **Documentation navigable** | [ops-nc.github.io/Vagrant-kubeadm](https://ops-nc.github.io/Vagrant-kubeadm/) — bascule EN/FR, thème clair/sombre, copie hors ligne avec `make docs` |
| 📦 **Couche applicative** | [ops-nc.github.io/k8s-playground](https://ops-nc.github.io/k8s-playground/) — dépôt à part, monté ici comme sous-module `_k8s/` |
| ⬆️ **Montée de version Kubernetes** | [`kubeadm/MISE-A-JOUR.md`](kubeadm/MISE-A-JOUR.md) |
| 🚑 **Quelque chose casse ?** | [`DEPANNAGE.md`](DEPANNAGE.md) |

> ⚠️ **`--recurse-submodules` n'est pas optionnel.** `_k8s/` est un **sous-module git** qui
> pointe sur [k8s-playground](https://github.com/OPS-NC/k8s-playground) ; un `git clone` simple
> laisse le dossier **vide** et `./_k8s/install.sh` répond `No such file or directory`. Sur un
> clone déjà fait : `git submodule update --init --recursive` (§1).

> ℹ️ **Il existe un dépôt jumeau, [Vagrant-Talos](https://github.com/OPS-NC/Vagrant-Talos).**
> Même lab, même plan d'adressage, et **littéralement la même couche applicative** — les deux
> dépôts montent le même sous-module k8s-playground sous `_k8s/`. Ce qui est opposé, c'est l'OS
> et le modèle de pilotage : Talos est immuable, sans SSH ni gestionnaire de paquets, et se
> pilote entièrement par API depuis l'hôte. Ici on assume une distribution classique et on
> conduit `kubeadm` soi-même : plus de pièces mobiles, et c'est justement l'objectif — ce dépôt
> sert à voir ce qu'un installeur cache d'habitude.

---

## 🧰 1. Prérequis (sur l'hôte)

| Outil | Rôle | Installation |
|---|---|---|
| VirtualBox 7 | hyperviseur | https://www.virtualbox.org/ |
| Vagrant | création des VM | https://developer.hashicorp.com/vagrant |
| `git` | le dépôt **et son sous-module `_k8s/`** | https://git-scm.com/ |
| `kubectl` | utilisation du cluster | https://kubernetes.io/docs/tasks/tools/ |
| `helm` | addons `_k8s/` | https://helm.sh/docs/intro/install/ |
| `uv` *(optionnel)* | `make docs` | https://docs.astral.sh/uv/ |

C'est la liste complète. **Il n'y a pas de `talosctl` ici, et aucun binaire spécifique au
cluster à installer sur ton poste** : `kubeadm`, `kubelet`, `kubectl` et `containerd` vivent
*dans* les VM, posés par [`kubeadm/provision.sh`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/provision.sh) pendant le
`vagrant up`. La box Debian (`bento/debian-13`) est téléchargée par Vagrant à la première
utilisation ; aucun plugin n'est nécessaire.

`kubeadm/cluster-up.sh` n'en vérifie que deux au démarrage (`vagrant`, `kubectl`) et refuse de
partir sans eux.

**La couche applicative est un sous-module, et elle réclame une commande à elle.** `_k8s/`
n'est pas un dossier de ce dépôt : c'est une copie épinglée de
[OPS-NC/k8s-playground](https://github.com/OPS-NC/k8s-playground), le dépôt partagé avec le lab
jumeau Talos. Un clone sans `--recurse-submodules` le laisse vide :

```bash
git submodule update --init --recursive     # remplit _k8s/ sur un clone existant
git submodule update --remote _k8s          # l'amène au dernier commit amont
```

> ⚠️ **Un `git pull` ne met PAS le sous-module à jour.** Il ne déplace que *ce* dépôt, et la
> copie `_k8s/` reste sur le commit épinglé auparavant. Après chaque pull, lancer
> `git submodule update --init --recursive` — sinon on exécute les commandes documentées contre
> une couche applicative plus ancienne. Un `git status` qui affiche
> `modified: _k8s (new commits)` signifie simplement que la copie ne correspond plus à
> l'épinglage.

> 💡 **Garde `kubectl` à une mineure près du cluster** (1.35 → 1.37 pour un cluster 1.36). Si
> le tien est plus ancien, celui des VM reste disponible :
> `vagrant ssh k8s-cp1 -c 'kubectl get nodes -o wide'` — `node-init.sh` installe un kubeconfig
> pour `root` comme pour `vagrant`.

> ⚠️ **VirtualBox et KVM ne peuvent pas partager VT-x.** Si le module KVM est chargé,
> `vagrant up` meurt sur `VERR_VMX_IN_VMX_ROOT_MODE`. Le décharger d'abord
> (`sudo modprobe -r kvm_intel kvm` / `kvm_amd`) — détails dans
> [`DEPANNAGE.md`](DEPANNAGE.md).

---

## 🗺️ 2. Plan d'adressage (réseau host-only `192.168.56.0/24`)

| Élément | IP |
|---|---|
| Hôte (passerelle host-only) | `192.168.56.1` |
| Serveur DHCP VirtualBox | `192.168.56.2` |
| **VIP de l'API Kubernetes** (keepalived) | **`192.168.56.5`** |
| `k8s-cp1` / `cp2` / `cp3` | `192.168.56.10` / `.20` / `.30` |
| `k8s-w1` / `w2` / `w3` … | `192.168.56.101` / `.102` / `.103` … |
| DHCP host-only par défaut de VirtualBox (réservée) | `192.168.56.100` |
| Plage LoadBalancer (annonce L2 Cilium) | `192.168.56.200` – `.230` |
| **IP du Gateway Envoy** (cible du DNS wildcard) | `192.168.56.200` — la 1re de la plage |

Réseau des pods `10.244.0.0/16`, réseau des Services `10.96.0.0/12`.

Les IP des nodes sont **statiques**, posées par le `Vagrantfile` (`private_network`) et non
par DHCP. Le `Vagrantfile` refuse de démarrer si une IP calculée tombe sur `.1`, `.2`, `.100`
ou sur la VIP, et refuse les doublons — ces cas produisent des labs cassés de façon très
obscure.

Chaque VM a **2 cartes** : **NIC1 = NAT VirtualBox** (Internet, le même `10.0.2.15` sur
*toutes* les VM) et **NIC2 = host-only** `192.168.56.x` (cluster, API, etcd, trafic des pods).
La route par défaut passe par le NAT — c'est délibéré, c'est ainsi que les VM atteignent `apt`
et les registries. Ce qui doit être host-only, c'est l'*identité* du node, jamais sa route par
défaut : voir la discussion sur `node-ip` en §9.

> ℹ️ **Le nom de l'interface host-only n'est jamais codé en dur.** Debian 13 la nomme en
> principe `enp0s8`, mais certaines box exposent encore `eth1`. `provision.sh` la détecte en
> cherchant l'interface qui *porte l'IP du node* (à défaut, la route vers `192.168.56.0/24`),
> l'écrit dans `/etc/kubeadm-lab/node.env`, et `cluster-up.sh` la recopie dans
> `_out/cluster.env` sous `HOSTONLY_IF`. keepalived y attache VRRP, et les scripts `_k8s/` la
> passent à Cilium pour l'annonce L2 — un mauvais nom là, c'est une VIP qui ne monte jamais et
> des Services qui ne répondent pas.

> ℹ️ La résolution des noms ne dépend ni du DNS, ni de l'ordre de démarrage : le `Vagrantfile`
> pousse un bloc `/etc/hosts` identique sur tous les nodes (tous les noms, plus
> `kubernetes-api` pour la VIP), et `provision.sh` supprime la ligne `127.0.1.1 <hostname>` de
> Debian — laissée en place, le kubelet résout son propre nom en loopback et le node
> s'enregistre injoignable.

---

## ⚙️ 3. Choisir la topologie — `lab.env`

La topologie vit dans **`lab.env`**, source unique lue par le `Vagrantfile`, par
`kubeadm/cluster-up.sh` **et** par les scripts `_k8s/*-up.sh`. Partir du modèle versionné
([`lab.env.example`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/lab.env.example) ; `lab.env` est gitignoré) :

```bash
cp lab.env.example lab.env
```

Le format est strict : une affectation `KEY=value` par ligne, sans espace autour du `=`. Une
vraie variable d'environnement reste prioritaire, ce qui permet les surcharges ponctuelles :
`WORKERS=5 vagrant up`.

| Variable | Défaut du modèle | Rôle |
|---|---|---|
| `K8S_VERSION` | `1.36.3` | version installée (`kubelet`/`kubeadm`/`kubectl`, épinglés puis `apt-mark hold`) |
| `K8S_APT_MINOR` | `v1.36` | mineure du dépôt `pkgs.k8s.io` — **doit correspondre à `K8S_VERSION`** |
| `CONTAINERD_SOURCE` | `docker` | `docker` → `containerd.io` 2.x (dépôt Docker) · `debian` → containerd 1.7 (cf. §9) |
| `REGISTRY_MIRROR` | *(vide)* | miroir pull-through (Harbor…) → `/etc/containerd/certs.d/docker.io/hosts.toml` |
| `CONTROL_PLANES` | `1` | `1` = simple, `3` = HA. **Un nombre pair est refusé** |
| `WORKERS` | `2` | nombre de workers ; `0` est valide (cf. `UNTAINT_CP`) |
| `CP_MEM` / `CP_CPU` | `3072` / `2` | ressources des control planes (**jamais sous `3072`** : etcd) |
| `WK_MEM` / `WK_CPU` | `2048` / `2` | ressources des workers |
| `BOX` | `bento/debian-13` | box Vagrant — le lab est écrit et testé pour Debian 13 |
| `NODE_PREFIX` | `k8s` | noms des VM/nodes : `k8s-cp1`, `k8s-w1`… |
| `CLUSTER_NAME` | `kubeadm-lab` | `clusterName` kubeadm + contexte kubeconfig |
| `NETWORK` | `192.168.56` | réseau host-only (3 premiers octets) |
| `VIP` | `192.168.56.5` | VIP de l'API = `controlPlaneEndpoint`, portée par keepalived |
| `CP_IP_START` / `CP_IP_STEP` | `10` / `10` | → `.10`, `.20`, `.30` |
| `WK_IP_START` / `WK_IP_STEP` | `101` / `1` | → `.101`, `.102`, `.103` |
| `POD_CIDR` | `10.244.0.0/16` | `networking.podSubnet` kubeadm — **le CNI doit annoncer le même** |
| `SERVICE_CIDR` | `10.96.0.0/12` | `networking.serviceSubnet` kubeadm |
| `LB_POOL_START` / `LB_POOL_END` | `192.168.56.200` / `.230` | plage des IP `LoadBalancer` ; **la 1re est celle du Gateway**, cible du DNS wildcard |
| `VRRP_ROUTER_ID` | `51` | groupe VRRP keepalived (1-255) ; à changer seulement pour cohabiter avec un autre lab keepalived |
| `CNI` | `cilium` | `cilium`, `calico`, `flannel` ou `none` (cf. §10) |
| `CILIUM_VERSION` | `1.20.0` | version du chart Cilium (ignorée si `CNI != cilium`) |
| `KUBE_PROXY_REPLACEMENT` | `true` | remplacement eBPF de kube-proxy — **exige `CNI=cilium`** |
| `UNTAINT_CP` | `auto` | retirer le taint control-plane : `auto` (seulement si `WORKERS=0`), `true`, `false` |
| `LAB_DOMAIN` | `kubeadm.lab.example.io` | domaine des UI (`*.<domaine>` : wildcard TLS + `HTTPRoute`) |
| `SELF_SIGNED` | `true` | mode TLS : `true` = wildcard signé par une AC locale (`openssl`, sans domaine ni token), `false` = cert-manager + Let's Encrypt |
| `LAB_DNS_ZONE` | *(vide → 2 derniers labels)* | zone DNS du solveur ACME DNS-01 — `SELF_SIGNED=false` seulement |
| `LAB_ACME_EMAIL` | *(vide → `admin@<zone>`)* | compte Let's Encrypt (avis d'expiration) — `SELF_SIGNED=false` seulement |
| `LAB_ACME_ISSUER` | `staging` | émetteur ACME : `staging` (non trusté, quota énorme) ou `prod` (trusté, **5 certs/semaine**) — `SELF_SIGNED=false` seulement |
| `CLOUDFLARE_API_TOKEN` | *(vide)* | DNS-01 de cert-manager — `SELF_SIGNED=false` seulement, et **jamais** dans le modèle versionné |

Lues par `cluster-up.sh` mais absentes du modèle (toutes deux ont un défaut) : `OUT` (`_out`,
le dossier où sont rendues les configurations) et `WAIT_API` (`600`, secondes d'attente de
l'apiserver sur la VIP).

> 💰 **Ce que coûte chaque topologie.** Par défaut (1 CP + 2 workers) : **7 Go de RAM**,
> 6 vCPU. HA complète (`CONTROL_PLANES=3`, `WORKERS=3`) : 3 × 3072 + 3 × 2048 = **15,4 Go**,
> 12 vCPU. Les disques des VM sont des clones liés : la box n'est stockée qu'une fois ou
> presque.

> ⚠️ **Un nombre PAIR de control planes est refusé**, par le `Vagrantfile` *et* par
> `cluster-up.sh`. etcd tient le quorum à `(n/2)+1` : avec 2 membres, la perte d'un seul node
> fige l'API — deux fois le coût d'un CP unique, pour strictement moins de disponibilité.
> Reste sur 1, 3 ou 5. (La CI teste que ce garde-fou se déclenche vraiment.)

> ⚠️ **Ne descends pas `CP_MEM` sous `3072`.** Le preflight kubeadm exige 2 vCPU et
> ~1700 Mio ; 2048 passe mais ne laisse que ~350 Mio de marge à un etcd empilé, qui s'effondre
> dès qu'on empile les addons `_k8s/`. `_k8s/observability/` réclame explicitement `4096`.

> ⚠️ **`K8S_VERSION` et `K8S_APT_MINOR` doivent concorder.** Les dépôts `pkgs.k8s.io` sont
> par mineure : un dépôt `v1.36` ne peut pas servir un paquet `1.35.x`, et `apt` échoue alors
> sur une erreur de version introuvable qui ne dit rien du décalage. C'est ce couple qu'on
> incrémente pour une montée de version — cf. [`kubeadm/MISE-A-JOUR.md`](kubeadm/MISE-A-JOUR.md).

> 💡 **Crée quand même `lab.env`.** Sans lui, le `Vagrantfile` et `cluster-up.sh` retombent
> chacun sur leurs défauts internes. Ils sont maintenus alignés volontairement — `make
> validate-defaults` le vérifie clé par clé — mais ce sont deux copies distinctes : le jour où
> elles divergent, tu obtiens des paquets 1.36 configurés pour 1.35. Un seul fichier, une
> seule vérité.

---

## 🚀 4. Démarrer le cluster

```bash
vagrant up                      # 5-10 min : VM + paquets + containerd + kubeadm + keepalived
./kubeadm/cluster-up.sh         # 3-5 min : init + jonctions + kubeconfig
```

**`vagrant up` ne bootstrape rien.** Il crée les VM et exécute dans chacune
[`kubeadm/provision.sh`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/provision.sh), qui pose, dans l'ordre : `/etc/hosts` · swap
coupé + modules noyau + sysctl · paquets de base (`conntrack`, `socat`, `ethtool`,
`open-iscsi`, `nfs-common`…) · containerd avec `SystemdCgroup = true` ·
`kubelet`/`kubeadm`/`kubectl` épinglés et gelés · **images pré-tirées** · et, sur les control
planes uniquement, **keepalived qui porte la VIP**. À la fin du `vagrant up`, chaque VM est
prête à recevoir un `kubeadm init` ou `join`, et rien de plus.

`cluster-up.sh` affiche ensuite cinq étapes :

| Étape | Ce qui se passe |
|---|---|
| `[1/5]` | rend les configurations kubeadm dans `_out/` **sur l'hôte** (`certsans.txt`, `kubeadm-init.yaml`) depuis [`kubeadm/templates/`](https://github.com/OPS-NC/Vagrant-kubeadm/tree/main/kubeadm/templates) |
| `[2/5]` | `kubeadm init` sur le 1er CP via `vagrant ssh` → [`node-init.sh`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/node-init.sh) ; copie `admin.conf` vers `./kubeconfig` ; **attend `https://<VIP>:6443/readyz`** |
| `[3/5]` | joint les control planes secondaires, **un à la fois** (etcd n'accepte qu'un changement d'appartenance à la fois) |
| `[4/5]` | joint les workers |
| `[5/5]` | déteinte selon `UNTAINT_CP`, étiquette les workers `node-role.kubernetes.io/worker=`, écrit `_out/cluster.env` (dont le `HOSTONLY_IF` détecté) |

Avant de toucher à quoi que ce soit, il valide la configuration (valeur de `CNI`, couple
`KUBE_PROXY_REPLACEMENT`/`CNI`, nombre impair de CP) et vérifie que **toutes** les VM
attendues sont `running` — diagnostiquer ça d'emblée coûte une seconde, le diagnostiquer plus
tard, c'est un `vagrant ssh` qui part en timeout au milieu d'un `join` à moitié fait.

Ensuite, depuis l'hôte :

```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide
```

Le kubeconfig n'a rien à retoucher : son `server:` est déjà la VIP, joignable depuis l'hôte
par le réseau host-only.

> ⚠️ **Les nodes seront `NotReady`, et c'est NORMAL.** C'est la question numéro un de qui
> découvre kubeadm : **kubeadm n'installe jamais de CNI**. Tant qu'aucun réseau de pods n'est
> posé, le kubelet remonte `NetworkReady=false` / `cni plugin not initialized`, CoreDNS reste
> `Pending`, et les nodes restent `NotReady`. La commande suivante est celle qui corrige ça :
> `./_k8s/install.sh kubeadm platform` (§6).

> 💡 **`cluster-up.sh` est idempotent** et se relance sans risque : `node-init.sh` refuse de
> rejouer `kubeadm init` si `/etc/kubernetes/admin.conf` existe, `node-join.sh` saute tout
> node qui a déjà `/etc/kubernetes/kubelet.conf`. Le relancer est d'ailleurs **la façon
> d'agrandir le lab** (§7.1).

> ℹ️ Les éléments de jonction sont régénérés à **chaque** exécution — le token créé par
> `init` expire en 24 h et la clé de certificats en 2 h. Un `cluster-up.sh` lancé trois jours
> après le `init` initial fonctionne donc, au lieu d'échouer sur une erreur de découverte
> opaque.

Pour une autre topologie, édite `lab.env` — ou surcharge à la volée, **en passant la variable
aux deux commandes**, chacune relisant son propre environnement :

```bash
CONTROL_PLANES=3 WORKERS=3 vagrant up
CONTROL_PLANES=3 WORKERS=3 ./kubeadm/cluster-up.sh
```

---

## 🎓 5. Faire la même chose à la main

C'est *à ça* que sert ce lab. Tout ce que fait `cluster-up.sh` est une commande `kubeadm` que
tu peux taper toi-même ; les scripts existent pour éviter de les retaper à chaque
reconstruction, pas pour les cacher. Voici le même parcours, à la main, sur un lab déjà passé
par `vagrant up`.

### 5.1 Ce qui est déjà en place après `vagrant up`

```bash
vagrant ssh k8s-cp1
sudo -i
kubeadm version -o short                 # v1.36.3, gelé par apt-mark
containerd --version                     # 2.x quand CONTAINERD_SOURCE=docker
crictl ps                                # parle à /run/containerd/containerd.sock
ip -4 addr show | grep 192.168.56.5      # la VIP est DÉJÀ là, avant tout init
systemctl status keepalived
cat /etc/kubeadm-lab/node.env            # NODE_IP, HOSTONLY_IF, VIP…
```

> ℹ️ Que la VIP soit levée **avant** le `kubeadm init` est toute la raison d'utiliser
> keepalived ici plutôt que kube-vip — le raisonnement est en §9.

### 5.2 `kubeadm init` sur le premier control plane

La façon du dépôt, qui est aussi la plus courte — `cluster-up.sh` a déjà rendu la
configuration dans `_out/`, visible depuis la VM par le dossier synchronisé :

```bash
sudo kubeadm init --config /vagrant/_out/kubeadm-init.yaml --upload-certs \
     --skip-phases=addon/kube-proxy          # seulement si KUBE_PROXY_REPLACEMENT=true
```

L'équivalent en drapeaux, pour voir la chose sans fichier de configuration :

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

Noter les deux adresses, qui ne sont **pas** la même chose :
`--apiserver-advertise-address` est l'IP *réelle* sur laquelle CET apiserver écoute,
`--control-plane-endpoint` est la VIP *partagée*, gravée dans les certificats et dans tous les
kubeconfig.

> ⚠️ **Cette forme en drapeaux ne sait pas poser `node-ip`, et c'est pour ça que le dépôt
> passe par `--config`.** Avec les seuls drapeaux, le kubelet prend la carte de la route par
> défaut — le NAT, `10.0.2.15`, **identique sur toutes les VM**. Tous les nodes s'enregistrent
> alors avec la même adresse : `kubectl get nodes -o wide` semble plausible, pendant que les
> logs, `kubectl exec`, les probes et le trafic inter-node partent au mauvais endroit.
> `kubeadm init/join` n'a aucun drapeau équivalent ; le réglage n'existe que sous
> `nodeRegistration.kubeletExtraArgs`.

> ⚠️ **`--upload-certs` est ce qui rendra la HA possible plus tard.** Il dépose les CA du
> cluster dans le Secret `kubeadm-certs`, chiffré par la clé de certificats. Sans lui, un
> second control plane ne peut rejoindre qu'après recopie manuelle de `/etc/kubernetes/pki`.

> ⚠️ **Les certSANs ne s'ajoutent pas après coup** — pas sans régénérer le certificat de
> l'API. C'est pourquoi le lab déclare d'avance **5** IP de control plane, y compris de nodes
> qui n'existent pas encore : agrandir le cluster ne demandera jamais de toucher à la PKI.

### 5.3 Récupérer un kubeconfig

Dans la VM :

```bash
mkdir -p "$HOME/.kube"
sudo install -o "$(id -u)" -g "$(id -g)" -m 0600 /etc/kubernetes/admin.conf "$HOME/.kube/config"
kubectl get nodes
```

Sur l'hôte — aucun `scp`, le dossier synchronisé est là :

```bash
vagrant ssh k8s-cp1 -c 'sudo cat /etc/kubernetes/admin.conf' > kubeconfig
chmod 0600 kubeconfig && export KUBECONFIG="$PWD/kubeconfig"
```

Il fonctionne tel quel parce que `server:` pointe sur la VIP, que l'hôte sait joindre.

### 5.4 Joindre un worker

```bash
# sur le control plane — imprime une commande prête à coller, token valable 24 h
sudo kubeadm token create --print-join-command
# kubeadm join 192.168.56.5:6443 --token <t> --discovery-token-ca-cert-hash sha256:<h>
```

```bash
# sur le worker
sudo kubeadm join 192.168.56.5:6443 --token <t> --discovery-token-ca-cert-hash sha256:<h>
```

> ⚠️ **Cette ligne imprimée est précisément ce que ce lab n'utilise PAS.** Elle ne sait pas
> transporter `node-ip` (cf. 5.2) : un node joint ainsi s'enregistre avec `10.0.2.15`. Le
> dépôt rend à la place un fichier `JoinConfiguration`
> ([`kubeadm-join-worker.yaml.tpl`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/templates/kubeadm-join-worker.yaml.tpl)) et lance
> `kubeadm join --config /vagrant/_out/join-<node>.yaml`. Si tu joins à la main et que tous
> les nodes affichent la même `INTERNAL-IP`, c'est là qu'il faut regarder.

### 5.5 Joindre un second control plane

Deux ingrédients de plus : la **clé de certificats**, qui déchiffre le Secret `kubeadm-certs`,
et `--control-plane`.

```bash
# sur cp1 — rechiffre le Secret et imprime une NOUVELLE clé en dernière ligne
sudo kubeadm init phase upload-certs --upload-certs

# en une commande, la ligne de jonction complète
sudo kubeadm token create --print-join-command \
  --certificate-key "$(sudo kubeadm init phase upload-certs --upload-certs | tail -n1)"
```

```bash
# sur cp2
sudo kubeadm join 192.168.56.5:6443 --token <t> --discovery-token-ca-cert-hash sha256:<h> \
  --control-plane --certificate-key <clé>
```

> ⚠️ **La clé de certificats expire en 2 heures**, le token en 24. Les deux se régénèrent sans
> risque (commandes ci-dessus) ; un élément périmé produit une erreur de déchiffrement qui ne
> parle jamais d'expiration.

> ⚠️ **`--config` et `--certificate-key` sont incompatibles.** Avec un fichier de
> configuration, la clé va sous `controlPlane.certificateKey` — et *non* à la racine du
> document, contrairement à `InitConfiguration`. Cf.
> [`kubeadm-join-cp.yaml.tpl`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/templates/kubeadm-join-cp.yaml.tpl).

> ⚠️ **Joins les control planes un à la fois.** Chaque jonction ajoute un membre etcd, et etcd
> n'accepte qu'un changement d'appartenance à la fois. En parallèle, le second échoue sur une
> erreur de quorum difficile à lire et facile à mal diagnostiquer.

### 5.6 Ce qui a changé par rapport aux anciennes notes kubeadm

Le dépôt est né d'un pas-à-pas manuscrit
(`README-installkubeadm.md`, conservé pour l'archéologie). Quatre
habitudes de cette époque ne sont plus justes :

| Ancienne habitude | Ce qu'il faut faire aujourd'hui |
|---|---|
| clé GPG du dépôt `v1.35`, `sources.list` pointant sur `v1.34` | la clé et le dépôt doivent être **de la même mineure**, et cette mineure doit correspondre à `K8S_VERSION` — c'est pour ce décalage que le couple vit dans `lab.env` |
| `apt-get install -y kubelet kubeadm kubectl` (sans épinglage) | épingler la version exacte (`kubelet=1.36.3-*`) puis `apt-mark hold` : sinon un `apt upgrade` involontaire casse le skew kubelet/apiserver |
| `apt-get install containerd` (Debian, 1.7.x) | containerd **2.x** du dépôt Docker — la 1.7 n'a pas la méthode CRI `RuntimeConfig` et c'est une impasse (§9) |
| `sandbox_image = "registry.k8s.io/pause:3.10.2"` codé en dur | demander à l'outil : `kubeadm config images list` — et en containerd 2.x la clé est `sandbox` sous `[plugins.'io.containerd.cri.v1.images'.pinned_images]` |
| `kubeadm init --apiserver-advertise-address 192.168.56.10` (sans VIP) | `--control-plane-endpoint <VIP>:6443` dès le départ, même avec un seul CP (§9) |

---

## 📦 6. La suite : la couche applicative

Un cluster nu ne sert à rien — et ici il n'est même pas `Ready`. Tout le reste — Cilium, Envoy
Gateway, cert-manager, metrics-server, Longhorn, Vault, CloudNativePG, Prometheus/Loki,
Kyverno, Trivy, MinIO, Argo CD… — vient d'un **dépôt séparé**,
[k8s-playground](https://github.com/OPS-NC/k8s-playground), monté ici comme sous-module
`_k8s/`.

Cette couche était auparavant dupliquée dans ce dépôt et dans le jumeau Talos. Elle est
désormais maintenue **une seule fois**, et la distribution visée est devenue un **argument** —
d'où un point d'entrée `install.sh <distro> …` et non plus un `platform-up.sh` seul. Sa
documentation est publiée à part : **<https://ops-nc.github.io/k8s-playground/>**.

```bash
./kubeadm/cluster-up.sh                     # 1. le cluster (NotReady : pas encore de CNI)

export KUBECONFIG="$PWD/kubeconfig"         # 2. où est le cluster
export LAB_DIR="$PWD"                       #    où sont lab.env et _out/ — voir plus bas

./_k8s/install.sh kubeadm platform          # 3. CNI → Envoy Gateway → metrics-server → TLS
./_k8s/install.sh kubeadm longhorn vault argocd   # 4. addons optionnels
```

Variantes utiles — la distribution (`kubeadm`) est toujours le **premier argument
positionnel** :

| Commande | Ce qu'elle fait |
|---|---|
| `./_k8s/install.sh kubeadm list` | le catalogue complet des addons |
| `./_k8s/install.sh kubeadm all` | la plateforme + tous les addons, dans l'ordre des dépendances |
| `./_k8s/longhorn/longhorn-up.sh kubeadm` | un addon tout seul |

La distribution se résout dans cet ordre : **1er argument positionnel** → `--distro=` → la
variable d'environnement `K8S_DISTRO` → `DISTRO=` dans `lab.env`. À défaut, les scripts
refusent de partir, plutôt que d'appliquer un manifeste taillé pour Talos sur du Debian.

`install.sh kubeadm platform` installe le CNI en premier ; les nodes passent `Ready` une à deux
minutes après cette étape. Chaîne de dépendances complète, liste des addons et pièges propres à
chacun : **<https://ops-nc.github.io/k8s-playground/>**.

> ⚠️ **`export LAB_DIR="$PWD"` est obligatoire dans cette disposition — c'est LE piège.**
> k8s-playground cherche `lab.env` et `_out/` dans cet ordre : `$LAB_DIR` / `$LAB_ENV`, puis sa
> propre racine, puis `<sa racine>/../Vagrant-KubeADM`. Monté en sous-module, sa racine **est**
> `Vagrant-KubeADM/_k8s` : ce dernier chemin devient donc `Vagrant-KubeADM/Vagrant-KubeADM`,
> qui n'existe pas. La résolution retombe alors sur `_k8s/` lui-même, où il n'y a ni `lab.env`
> ni `_out/` : les scripts tourneraient sur leurs valeurs par défaut — **mauvais domaine,
> mauvais CNI** — et sans kubeconfig. `LAB_DIR` est la variable prévue exactement pour ce cas ;
> l'exporter à côté de `KUBECONFIG`, à chaque fois.

> ⚠️ **Si `_k8s/` est vide**, le sous-module n'a jamais été initialisé :
> `git submodule update --init --recursive` (§1). Pour récupérer une couche applicative plus
> récente : `git submodule update --remote _k8s`.

> ⚠️ **Cette couche suppose `CNI=cilium`** (le défaut). Elle a besoin d'un Service
> `LoadBalancer` qui obtient réellement une IP, ce que seule l'annonce L2/ARP de Cilium
> fournit sur un réseau host-only. Avec `calico`, `flannel` ou `none`, le Gateway reste en
> `EXTERNAL-IP <pending>` et aucune UI n'est joignable. Détails en §10.

### 6.1 Les deux prérequis manuels

Rien dans le cluster ne peut les faire à ta place.

**a) Faire résoudre `*.<LAB_DOMAIN>` vers l'IP du Gateway.** Toutes les UI du lab passent par
un point d'entrée unique — le Service `LoadBalancer` d'Envoy, qui prend la **première IP de
`LB_POOL_START`**, `192.168.56.200` par défaut. Avec `SELF_SIGNED=true` (le défaut), une ligne
dans le `/etc/hosts` de l'hôte suffit, aucun enregistrement DNS public n'est nécessaire :

```bash
kubectl -n envoy-gateway-system get svc -o wide | grep LoadBalancer   # l'IP réellement posée
# /etc/hosts
# 192.168.56.200  argo.kubeadm.lab.example.io grafana.kubeadm.lab.example.io
```

Avec `SELF_SIGNED=false`, il faut un vrai enregistrement `A` wildcard `*.<LAB_DOMAIN>` vers
l'IP du Gateway, en **DNS-only** (un proxy CDN ne peut pas joindre une origine privée en
`192.168.56.x`).

**b) Choisir le mode TLS**, avec `SELF_SIGNED` dans `lab.env`. `true` : `platform-up.sh`
fabrique une AC locale et un certificat wildcard avec `openssl`, n'installe pas cert-manager,
n'exige ni token ni domaine public — le navigateur avertit tant que `_out/self-signed/ca.crt`
n'est pas importée. `false` : cert-manager + Let's Encrypt en ACME DNS-01, ce qui suppose un
domaine réel, `CLOUDFLARE_API_TOKEN`, et de respecter le quota de production de **5
certificats par semaine** (`LAB_ACME_ISSUER=staging` est le défaut pour exactement cette
raison). Les deux chemins remplissent le même Secret
`wildcard-<LAB_DOMAIN avec des tirets>-tls` : aucun addon n'a donc à savoir lequel tu as
choisi.

---

## ♻️ 7. Cycle de vie

```bash
vagrant status                 # état des VM
vagrant halt                   # extinction (le cluster revient au `up` suivant)
vagrant up                     # rallumage
vagrant destroy -f             # suppression de toutes les VM
```

Après un `destroy`, nettoyer aussi l'état côté hôte avant de reconstruire :

```bash
rm -rf _out kubeconfig
```

Garder le dépôt à jour, c'est **deux** commandes et non une — `git pull` ne déplace que ce
dépôt et laisse `_k8s/` sur le commit épinglé auparavant :

```bash
git pull                                  # ce dépôt (Vagrantfile, kubeadm/, docs)
git submodule update --init --recursive   # _k8s/ ramené sur le commit épinglé ici
git submodule update --remote _k8s        # ou : sauter au dernier k8s-playground
```

### 7.1 Agrandir le lab

`cluster-up.sh` est idempotent, et c'est *la* procédure d'ajout de nodes :

1. augmenter `WORKERS` (ou `CONTROL_PLANES`, en le gardant impair) dans `lab.env` ;
2. `vagrant up` — seules les nouvelles VM sont créées et préparées ;
3. `./kubeadm/cluster-up.sh` — il saute tout ce qui est en place et ne joint que les nouveaux
   nodes, avec des éléments de jonction fraîchement générés.

Aucune régénération de certificat n'est nécessaire : les `certSANs` couvrent déjà 5 IP de
control plane (§5.2).

Pour retirer un worker, le drainer d'abord, afin que le cluster cesse de planifier sur une
machine sur le point de disparaître :

```bash
kubectl drain k8s-w3 --ignore-daemonsets --delete-emptydir-data
vagrant destroy -f k8s-w3
kubectl delete node k8s-w3
```
puis baisser `WORKERS` dans `lab.env`.

### 7.2 Défaire le cluster sans détruire les VM

```bash
./kubeadm/cluster-reset.sh          # demande confirmation
./kubeadm/cluster-reset.sh --yes    # sans confirmation
```

Il lance `kubeadm reset` sur tous les nodes (**les workers d'abord**, pour qu'ils se
désinscrivent pendant que l'API répond encore), puis supprime `_out/` et `kubeconfig` sur
l'hôte. Les VM continuent de tourner, avec leurs paquets, containerd et keepalived intacts —
la reconstruction se résume alors à `./kubeadm/cluster-up.sh`, quelques minutes au lieu d'un
`vagrant up` complet.

À préférer à `vagrant destroy` pour **rejouer un bootstrap raté**, ou pour changer `POD_CIDR`,
`SERVICE_CIDR`, le CNI ou la VIP — tous les quatre sont figés au `kubeadm init` et ne se
changent pas sur un cluster en route.

> ⚠️ **Destructif** : etcd, les certificats et toutes les charges sont perdus, y compris ce
> qui vit dans un PersistentVolume adossé au disque d'un node.

> ℹ️ **Pourquoi un reset dédié et pas seulement `kubeadm reset`** : `kubeadm reset` laisse
> volontairement derrière lui ce qu'il n'a pas posé — les interfaces CNI (`cilium_host`,
> `lxc*`, `flannel.1`, `cali*`), les **programmes eBPF épinglés de Cilium sous `/sys/fs/bpf`**
> (qui survivent au DaemonSet et continuent d'intercepter le trafic d'un cluster qui n'existe
> plus), et les règles iptables/ipvs de kube-proxy. [`node-reset.sh`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/node-reset.sh)
> fait ce ménage ; sans lui, le `init` suivant hérite d'un datapath fantôme et le réseau pod
> se comporte de façon qu'aucun log n'explique.

---

## 🚑 8. Dépannage

Les symptômes et leurs correctifs ont leur propre page, pour que celle-ci reste une page
d'installation : **[`DEPANNAGE.md`](DEPANNAGE.md)**. Les cas les plus probables :

- **Tous les nodes `NotReady`, CoreDNS `Pending`** → aucun CNI. Attendu jusqu'à
  `./_k8s/install.sh kubeadm platform` — kubeadm n'en installe jamais.
- **`./_k8s/install.sh: No such file or directory`** → le sous-module `_k8s/` n'a jamais été
  initialisé : `git submodule update --init --recursive`.
- **`cluster-up.sh` s'arrête sur « l'apiserver ne répond pas sur la VIP »** → soit keepalived
  ne porte pas la VIP (`vagrant ssh k8s-cp1 -c "ip -4 addr show | grep 192.168.56.5"`,
  `sudo systemctl status keepalived`), soit l'apiserver lui-même ne démarre pas
  (`sudo crictl ps -a | grep apiserver`, `sudo journalctl -u kubelet -n 50`).
- **Tous les nodes affichent la même `INTERNAL-IP` `10.0.2.15`** → un node joint sans
  `node-ip`, c'est-à-dire avec la ligne `kubeadm join` imprimée au lieu du
  `JoinConfiguration` rendu (§5.4).
- **`vagrant up` meurt sur `VERR_VMX_IN_VMX_ROOT_MODE`** → le module KVM tient VT-x ; le
  décharger.
- **Le Gateway reste en `EXTERNAL-IP <pending>`** → `CNI` n'est pas `cilium`, donc personne
  n'annonce les IP LoadBalancer sur le réseau host-only (§10).

Les problèmes propres à un addon sont documentés avec les addons eux-mêmes, dans les sections
⚠️ pièges et 🚑 dépannage des pages k8s-playground :
**<https://ops-nc.github.io/k8s-playground/>**.

---

## 🔍 9. Comment ça marche sous le capot

### 9.1 La VIP est portée par keepalived, pas par kube-vip

C'est la décision la plus structurante du dépôt.

`controlPlaneEndpoint` pointe sur la VIP, et il est **figé dans les certificats et dans tous
les kubeconfig au moment du `kubeadm init`**. La VIP doit donc exister *avant* le init.

kube-vip, la réponse habituelle des guides kubeadm HA, tourne en pod statique et fait son
élection de leader **à travers l'API Kubernetes** — c'est-à-dire à travers la VIP qu'il est
censé porter. Œuf et poule. La sortie documentée consiste à le pointer sur
`--k8sConfigPath /etc/kubernetes/super-admin.conf`, elle-même fragile depuis que Kubernetes
1.29 a sorti `admin.conf` du groupe `system:masters`
([kube-vip#684](https://github.com/kube-vip/kube-vip/issues/684), toujours ouvert).

keepalived n'a rien de tout ça : c'est un simple démon VRRP, il ne connaît pas Kubernetes, il
lève la VIP dès le boot de la VM, et la dépendance circulaire disparaît. Sa configuration est
écrite par [`provision.sh`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/provision.sh) :

- **VRRP en unicast** (`unicast_src_ip` + `unicast_peer`), pas en multicast : sur un switch
  virtuel host-only VirtualBox, le multicast est la première chose à se comporter bizarrement,
  et on connaît de toute façon toutes les IP de control plane.
- **Priorités** cp1 = 100, cp2 = 90, cp3 = 80.
- **`vrrp_script chk_apiserver`** interroge `https://127.0.0.1:6443/livez/ping` toutes les 3 s avec
  `weight -30` : un control plane dont l'apiserver est mort tombe à 70 et passe derrière un
  cp2 sain à 90, qui reprend la VIP.
- `/livez/ping` est lisible **en anonyme** grâce au ClusterRoleBinding `system:public-info-viewer`
  posé par kubeadm — aucun credential à distribuer à un script de santé.
- **Tant qu'aucun cluster n'existe, le test échoue sur tous les CP** : chacun perd 30 points,
  l'ordre relatif est préservé, et la VIP est quand même portée. Exactement ce dont
  `kubeadm init` a besoin.
- **Pas de bloc `authentication`** : VRRPv2 transmet son mot de passe en clair et n'apporte
  rien. La frontière de confiance est ici le réseau host-only. Pour cohabiter avec un autre
  lab keepalived sur le même réseau, on change `VRRP_ROUTER_ID`.

> ℹ️ kube-vip reste une option parfaitement valable **une fois le cluster en route** (mode
> `--services`, pour les Services LoadBalancer). C'est le rôle au *bootstrap* qui ne passe
> pas ici.

### 9.2 La VIP est utilisée même avec un seul control plane

Parce que `controlPlaneEndpoint` est figé au `init`. En le pointant sur la VIP dès la première
exécution, passer de 1 à 3 control planes devient un simple `join` ; le pointer sur l'IP
réelle de cp1 imposerait de régénérer tous les certificats et de redistribuer tous les
kubeconfig.

### 9.3 containerd 2.x depuis le dépôt Docker, pas le paquet Debian

Debian 13 livre containerd **1.7.24**. Seule la branche 2.x implémente la méthode CRI
`RuntimeConfig`, dont kubeadm se sert pour lire le cgroup driver du runtime. En 1.36 son
absence n'est qu'un **avertissement** de preflight ; le repli disparaît en **1.37**, et le
backport vers la branche 1.7 a été **refusé**
([containerd#11346](https://github.com/containerd/containerd/issues/11346), fermé sans merge).
La 1.7 est une impasse. `CONTAINERD_SOURCE=debian` reste disponible pour un lab hors ligne.

`SystemdCgroup = true` compte davantage que le champ `cgroupDriver` du kubelet : Debian 13 est
en cgroup v2 avec systemd comme gestionnaire, et laisser containerd sur `cgroupfs` met deux
gestionnaires sur la même hiérarchie — les nodes deviennent alors instables sous charge.

> ⚠️ **Le piège de la migration 1.7 → 2.x** : la clé de l'image `pause` a changé de *nom et
> d'emplacement*. La config v2 a `sandbox_image = "..."` sous
> `[plugins."io.containerd.grpc.v1.cri"]` ; la v3 a `sandbox = '...'` sous
> `[plugins.'io.containerd.cri.v1.images'.pinned_images]`. Une config recopiée telle quelle
> perd silencieusement le réglage. `provision.sh` régénère le fichier depuis
> `containerd config default` à chaque passage et corrige la clé réellement présente.

> ℹ️ Le tag de `pause` lui-même n'est **jamais codé en dur** : il vient de
> `kubeadm config images list`. Un décalage entre le `pause` de containerd et celui qu'attend
> kubeadm est invisible en ligne (l'image est simplement retéléchargée) et fatal hors ligne.

### 9.4 `node-ip` forcé sur chaque node

Le piège numéro un de tout lab Kubernetes sous Vagrant, décrit en §5.2 : la carte NAT est en
`10.0.2.15` sur toutes les VM. Comme ni `kubeadm init` ni `kubeadm join` n'ont de drapeau pour
ça, le lab pilote les deux par des fichiers `InitConfiguration`/`JoinConfiguration` portant
`nodeRegistration.kubeletExtraArgs: [{name: node-ip, value: <IP host-only>}]`.

### 9.5 API kubeadm `v1beta4`

Version courante et par défaut depuis Kubernetes 1.31 ; `v1beta3` est dépréciée.

> ⚠️ **La rupture à connaître** : `extraArgs` et `kubeletExtraArgs` ne sont plus des
> **dictionnaires** mais des **listes de `{name, value}`** — pour autoriser un même drapeau
> plusieurs fois. Tout fichier écrit avant 1.31 est invalide tel quel, et l'erreur renvoyée
> par kubeadm ne désigne pas la forme fautive.
> ```yaml
> # v1beta3 :  extraArgs: {bind-address: "0.0.0.0"}
> # v1beta4 :  extraArgs: [{name: bind-address, value: "0.0.0.0"}]
> ```
> `make validate-kubeadm` attrape exactement ça, en CI, sans cluster.

### 9.6 Le dossier synchronisé `/vagrant` est un rouage, pas un confort

`cluster-up.sh` **ne fait rien lui-même dans les VM**. Il rend les configurations kubeadm dans
`_out/` sur l'hôte, puis appelle [`node-init.sh`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/node-init.sh) et
[`node-join.sh`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/kubeadm/node-join.sh) par `vagrant ssh` ; les VM lisent ces fichiers dans
`/vagrant/_out/`. Aucun `scp`, aucun secret passé en ligne de commande (où il finirait dans
l'historique du shell et dans la liste des processus), et la logique reste dans des fichiers
versionnés qui se relisent en diff, au lieu d'un enfer d'échappement dans un
`vagrant ssh -c`.

> ⚠️ `_out/join.env` contient le **token de jonction et la clé de certificats**. Le dossier
> est gitignoré, mais il est lisible depuis toutes les VM par le dossier synchronisé. C'est un
> lab : acceptable ici, à ne pas reproduire en production.

### 9.7 Ce que kubeadm ne fait pas, et que `cluster-up.sh` rattrape

- **Rôle des workers** : kubeadm ne pose aucun label de rôle ; `kubectl get nodes` affiche
  `<none>` dans la colonne ROLES et les sélecteurs `node-role.kubernetes.io/worker` ne
  matchent rien. `cluster-up.sh` pose le label.
- **Taint des control planes** : `UNTAINT_CP=auto` ne le retire que si `WORKERS=0` — sinon
  plus rien ne pourrait se planifier nulle part. C'est ce qui rend un lab à une seule VM
  utilisable.
- **Métriques du control plane** : `controllerManager` et `scheduler` reçoivent
  `bind-address: 0.0.0.0` ; par défaut ils n'écoutent qu'en loopback et Prometheus affiche
  deux cibles DOWN sans explication. Acceptable parce que le réseau host-only est isolé.
- **Images pré-tirées** : pendant le `vagrant up`, en parallèle sur toutes les VM, pour que
  `kubeadm init` n'ait plus rien à télécharger — la plus grosse source de timeouts au
  bootstrap. Les workers ne tirent que `pause` et `kube-proxy`, ce qui économise ~500 Mio
  chacun.
- **Swap** : coupé et masqué (y compris les unités systemd de swap, que `/etc/fstab` ne
  décrit pas). NodeSwap est GA depuis 1.34, mais `failSwapOn` vaut toujours `true` par défaut.

---

## 🌐 10. CNI : Cilium, Calico ou Flannel

**kubeadm n'installe jamais de CNI.** Contrairement au dépôt jumeau Talos — où flannel peut
être posé par l'OS au bootstrap —, ici le réseau des pods est *toujours* installé après coup,
par `./_k8s/install.sh kubeadm platform`. `CNI` dans `lab.env` est lu par `cluster-up.sh` (pour
la décision kube-proxy et `_out/cluster.env`) et par l'étape plateforme (quel chart installer).

| `CNI=` | Qui l'installe | IP `LoadBalancer` | Couche `_k8s/` utilisable |
|---|---|---|---|
| **`cilium`** *(défaut)* | `install.sh kubeadm platform` → [`cilium/` de k8s-playground](https://github.com/OPS-NC/k8s-playground/blob/main/cilium/LISEZ-MOI.md) | ✅ pool + annonce L2/ARP | ✅ oui |
| `calico` | `install.sh kubeadm platform` → [`calico/` de k8s-playground](https://github.com/OPS-NC/k8s-playground/blob/main/calico/LISEZ-MOI.md) | ❌ BGP uniquement | ⚠️ MetalLB en plus |
| `flannel` | `install.sh kubeadm platform` | ❌ | ❌ non |
| `none` | toi | ❌ | dépend de ce que tu installes |

**En pratique : garde `cilium`.** C'est la seule valeur qui rend le lab utilisable de bout en
bout, parce que c'est la seule qui donne une `EXTERNAL-IP` aux Services sur un réseau
host-only — donc la seule qui te donne les UI HTTPS. `calico` est là pour comparer les CNI et
travailler les `NetworkPolicy` ; `flannel` pour un cluster volontairement nu.

> ⚠️ **`KUBE_PROXY_REPLACEMENT=true` exige `CNI=cilium`**, et `cluster-up.sh` refuse de
> démarrer avec toute autre combinaison. Avec `--skip-phases=addon/kube-proxy` et aucun
> remplaçant, **plus aucune ClusterIP ne répond** — pas même CoreDNS joignant l'API. Le
> message d'erreur propose les deux issues : `CNI=cilium`, ou `KUBE_PROXY_REPLACEMENT=false`.

> ℹ️ **Pourquoi Cilium a besoin de `k8sServiceHost`/`k8sServicePort`** quand kube-proxy
> disparaît : plus rien ne provisionne la ClusterIP de l'apiserver, et l'agent ne peut donc
> pas s'amorcer via `kubernetes.default`. Le lab l'y pointe sur la **VIP** — ce qui fait aussi
> que les agents survivent à la perte de n'importe quel control plane.

> ℹ️ Le lab utilise le drapeau `--skip-phases=addon/kube-proxy` plutôt que le champ
> déclaratif `proxy.disabled` de v1beta4 : résultat identique, mais le drapeau est éprouvé sur
> toutes les versions et c'est celui que documente Cilium.

> ⚠️ **`POD_CIDR` doit être le CIDR que le CNI annonce réellement.** Cilium en mode
> `cluster-pool` part par défaut sur `10.0.0.0/8`, sans rapport avec ce qu'on a déclaré à
> kubeadm ; le `cilium/cilium-up.sh` de k8s-playground lui repasse `POD_CIDR` explicitement.
> Deux valeurs divergentes donnent un réseau pod cassé qui a l'air configuré.

> ⚠️ **Changer de CNI sur un cluster existant n'est pas supporté.**
> `./kubeadm/cluster-reset.sh` (ou `vagrant destroy`) d'abord — deux CNI se battent pour le
> réseau des pods, et le datapath résiduel est précisément ce que `node-reset.sh` existe pour
> nettoyer.

---

## 🛠️ 11. Valider une modification

Tout se valide **sans monter de cluster** :

```bash
make validate       # shell + YAML + Vagrantfile + modèles kubeadm + liens de la doc
make docs           # régénère docs/index.html depuis tous les README (EN + FR)
make help           # liste les cibles
```

| Cible | Ce qu'elle couvre |
|---|---|
| `validate-shell` | `bash -n` sur tous les `*.sh` suivis par git |
| `validate-yaml` | parse tous les `*.yaml` / `*.yml` suivis par git (PyYAML, fourni par `uv`) |
| `validate-vagrant` | `vagrant validate` ; en local, valide en plus la configuration du provider |
| `validate-defaults` | vérifie que les défauts de repli du `Vagrantfile` et de `cluster-up.sh` correspondent toujours, clé par clé, à ceux de `lab.env.example` |
| `validate-kubeadm` | rend les 3 modèles avec des valeurs factices dans un dossier jetable, les parse, puis lance `kubeadm config validate` **si `kubeadm` est dans le PATH** |
| `validate-docs` | construit la doc dans un fichier jetable et échoue sur tout lien `*.md` mort ou ancre inter-page inconnue |

`validate-kubeadm` est la cible qui a le plus de valeur : c'est elle qui attrape une vraie
erreur de schéma v1beta4 — un `extraArgs` resté sous forme de dictionnaire v1beta3 — au lieu
de la découvrir dix minutes après le début d'un `vagrant up`. En CI, où `kubeadm` est installé
pour le job, la vérification de schéma tourne systématiquement.

**À chaque pull request**, le workflow `ci` rejoue les validations shell, défauts, YAML,
kubeadm et Vagrantfile en appelant exactement les mêmes cibles `make` : une vérification ne peut donc pas
passer en CI et échouer sur ton poste. Il vérifie aussi que le garde-fou se déclenche
vraiment : `CONTROL_PLANES=2 vagrant validate` **doit** être rejeté. `vagrant validate` y
tourne avec `--ignore-provider`, faute de VirtualBox sur un runner ; `validate-docs` est
couvert par le workflow `docs`.

> ℹ️ Rien dans le `Makefile` ne touche à un cluster en route, et rien ne régénère de secret.
> `make validate` est sans risque sur un lab démarré.

---

## 📄 12. Licence

Ce projet est sous **licence Apache 2.0** — cf.
[`LICENSE`](https://github.com/OPS-NC/Vagrant-kubeadm/blob/main/LICENSE).

En résumé : utilisation, modification et redistribution libres, y compris commerciales, tant
que l'avis de copyright est conservé et les modifications signalées. Le tout **sans aucune
garantie** : c'est un lab, pas de production.

La licence couvre ce que ce dépôt contient réellement — le `Vagrantfile`, les scripts
`kubeadm/`, les modèles, les manifestes et la documentation. Elle ne s'étend **pas** aux
composants tiers que ces scripts téléchargent (Kubernetes, containerd, keepalived, Cilium,
Envoy Gateway, Longhorn, Vault…), chacun conservant sa propre licence, ni au sous-module
`_k8s/` : [k8s-playground](https://github.com/OPS-NC/k8s-playground) est un dépôt séparé et
porte son propre `LICENSE`.
