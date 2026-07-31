<!-- i18n -->
[English](TROUBLESHOOTING.md) · **Français**
<!-- /i18n -->

# 🚑 Dépannage

> Organisé par **symptôme observé**, parce que c'est ce qu'on a sous les yeux : un message
> d'erreur, pas une théorie. Parcours d'installation : [`LISEZ-MOI.md`](LISEZ-MOI.md) · couche
> applicative : [`_k8s/LISEZ-MOI.md`](_k8s/LISEZ-MOI.md) · montées de version :
> [`kubeadm/MISE-A-JOUR.md`](kubeadm/MISE-A-JOUR.md).

Chaque `_k8s/<addon>/LISEZ-MOI.md` porte ses **propres** pièges, spécifiques à lui (Longhorn,
Vault, Calico…). Cette page couvre le lab lui-même : l'hôte, VirtualBox, keepalived, kubeadm et
les nodes Debian.

Sauf mention contraire, toutes les commandes se lancent **depuis la racine du dépôt**, avec :

```bash
export KUBECONFIG="$PWD/kubeconfig"
```

---

## 🖥️ 1. Hôte et VirtualBox

### `vagrant up` meurt sur `VERR_VMX_IN_VMX_ROOT_MODE`

```
VBoxManage: error: VT-x is being used by another hypervisor (VERR_VMX_IN_VMX_ROOT_MODE).
VBoxManage: error: VirtualBox can't operate in VMX root mode.
```

**Cause.** VirtualBox et KVM ne peuvent pas tenir **VT-x** en même temps. Si le module noyau
KVM est chargé — et sur la plupart des distributions Linux il l'est dès le démarrage —
VirtualBox ne peut lancer aucune VM.

```bash
# 1. KVM est-il chargé ? (Intel : kvm_intel — AMD : kvm_amd)
lsmod | grep kvm

# 2. Le décharger (échoue si une VM KVM/libvirt tourne encore — l'arrêter d'abord)
sudo modprobe -r kvm_intel kvm      # AMD : sudo modprobe -r kvm_amd kvm
```

> 💡 KVM revient à chaque démarrage. Si cet hôte ne sert **jamais** à KVM/libvirt, blackliste-le
> une bonne fois :
> ```bash
> echo -e "blacklist kvm_intel\nblacklist kvm" | sudo tee /etc/modprobe.d/disable-kvm.conf
> ```
> Pour revenir en arrière : supprimer ce fichier et redémarrer.

### VirtualBox refuse le réseau host-only `192.168.56.0/24`

VirtualBox 7 n'autorise que les adresses host-only explicitement permises. Autoriser la plage :

```
# /etc/vbox/networks.conf
* 192.168.56.0/21
```

Tout le lab vit dans ce `/24` (nodes, VIP `192.168.56.5`, plage LoadBalancer `.200`–`.230`) :
rien ne fonctionne tant que VirtualBox ne l'accepte pas.

### `vagrant up` refuse un nombre pair de control planes

```
Vagrant-KubeADM : CONTROL_PLANES=2 est PAIR — etcd exige un nombre impair pour tenir
un quorum utile (1, 3, 5). Avec 2 membres, la perte d'un seul node fige l'API.
```

**C'est un garde-fou, pas un bug.** etcd tient le quorum à `(n/2)+1` : deux membres ne tolèrent
**aucune** panne tout en coûtant deux fois plus cher qu'un seul. Mets `CONTROL_PLANES=1`, `3` ou
`5` dans `lab.env`. `kubeadm/cluster-up.sh` refuse la même valeur, volontairement — les deux
contrôles sont redondants exprès.

Le `Vagrantfile` refuse aussi une IP de node qui tombe sur `192.168.56.1` (passerelle
host-only), `.2` (DHCP VirtualBox), `.100` (plage DHCP host-only par défaut de VirtualBox) ou la
VIP, ainsi que deux nodes sur la même IP. Ces erreurs nomment toutes la variable en cause
(`CP_IP_START`/`CP_IP_STEP`, `WK_IP_START`/`WK_IP_STEP`).

---

## 🌐 2. La VIP de l'API et keepalived

### `cluster-up.sh` échoue sur « l'apiserver ne répond pas sur la VIP »

```
    - attente de https://192.168.56.5:6443 ......................... ÉCHEC (600s)
ERREUR : l'apiserver ne répond pas sur la VIP 192.168.56.5 après 600s.
```

À ce stade `kubeadm init` a déjà tourné : le script attend `/readyz` **à travers la VIP**, qui
est l'adresse que tous les autres nodes utiliseront pour rejoindre. Le script liste lui-même les
deux causes, par fréquence.

**Cause 1 — keepalived ne porte pas la VIP.**

```bash
vagrant ssh k8s-cp1 -c "ip -4 addr show | grep 192.168.56.5"
vagrant ssh k8s-cp1 -c "sudo systemctl status keepalived"
vagrant ssh k8s-cp1 -c "sudo journalctl -u keepalived -n 50 --no-pager"
```

Ce qu'il faut regarder :

| Observation | Signification |
|---|---|
| `ip -4 addr show` n'affiche rien pour `.5` | aucun node ne porte la VIP |
| `keepalived.service: failed`, `Cant find interface` dans le journal | keepalived a été configuré sur la mauvaise interface |
| `Entering BACKUP STATE` sur tous les control planes | les pairs se voient mais personne ne promeut |

L'interface est **détectée**, jamais codée en dur : `kubeadm/provision.sh` cherche celle qui
porte l'IP du node et l'écrit dans `/etc/kubeadm-lab/node.env`. Vérifie ce qu'il a trouvé :

```bash
vagrant ssh k8s-cp1 -c "cat /etc/kubeadm-lab/node.env"
vagrant ssh k8s-cp1 -c "sudo sed -n '/vrrp_instance/,\$p' /etc/keepalived/keepalived.conf"
```

Si `HOSTONLY_IF` est retombé sur `eth1` alors que la VM utilise réellement `enp0s8`, keepalived
s'accroche à une interface inexistante. Relance `vagrant provision k8s-cp1` une fois que la VM a
bien son adresse host-only.

**Cause 2 — l'apiserver lui-même ne démarre pas.**

```bash
vagrant ssh k8s-cp1 -c "sudo crictl ps -a | grep apiserver"
vagrant ssh k8s-cp1 -c "sudo journalctl -u kubelet -n 50 --no-pager"
vagrant ssh k8s-cp1 -c "sudo crictl logs \$(sudo crictl ps -a -q --name kube-apiserver | head -1)"
```

Un apiserver en `CrashLoopBackOff`, c'est presque toujours etcd en dessous : regarde
`crictl ps -a | grep etcd` et la section 5 plus bas. À noter : le test de santé de keepalived
(`/etc/keepalived/check-apiserver.sh`, qui interroge `https://127.0.0.1:6443/livez/ping` toutes les
3 s) ne retire que 30 points de priorité — il ne retire jamais la VIP. La VIP présente ne prouve
donc rien sur l'apiserver.

### La VIP est portée par DEUX nodes à la fois (split-brain VRRP)

**Symptôme.** `kubectl` se comporte de façon erratique — une requête passe, la suivante part en
timeout — et :

```bash
for n in k8s-cp1 k8s-cp2 k8s-cp3; do
  echo -n "$n : " ; vagrant ssh "$n" -c "ip -4 -o addr show | grep -c 192.168.56.5" -- -q
done
# sain : exactement un node répond 1, les autres 0
```

Le journal affiche `Entering MASTER STATE` sur **deux** nodes.

**Cause.** Le VRRP est ici en **unicast** (`unicast_src_ip` + `unicast_peer`), pas en multicast,
parce que le multicast est la première chose à se comporter bizarrement sur un switch host-only
VirtualBox. Un control plane qui ne voit pas ses pairs se croit seul et se promeut.

```bash
# La liste de pairs doit contenir toutes les AUTRES IP de control plane
vagrant ssh k8s-cp1 -c "sudo sed -n '/unicast/,/}/p' /etc/keepalived/keepalived.conf"

# Le router ID doit être IDENTIQUE sur tous les control planes
for n in k8s-cp1 k8s-cp2 k8s-cp3; do
  vagrant ssh "$n" -c "sudo sed -n 's/.*virtual_router_id //p' /etc/keepalived/keepalived.conf" -- -q
done

vagrant ssh k8s-cp2 -c "sudo journalctl -u keepalived -n 80 --no-pager"
```

Trois causes réelles, par ordre de probabilité :

1. **Bloc `unicast_peer` absent** — le node est retombé en multicast. Cela arrivait quand un
   control plane était provisionné alors que `CONTROL_PLANES` valait encore `1` : sans aucun
   pair à lister, keepalived ne **refuse pas** la configuration, il repasse silencieusement en
   multicast. Agrandir le lab ensuite laissait donc `cp1` en multicast pendant que `cp2`/`cp3`
   parlaient unicast — et les deux modes sont *mutuellement sourds*, si bien que chaque camp se
   croyait seul et prenait la VIP.
   `provision.sh` liste désormais toujours les **cinq** IP de control plane que permet le plan
   d'adressage : une configuration écrite pour un seul CP est déjà la bonne pour trois. Un node
   à qui il manque encore le bloc a été provisionné par une révision antérieure du dépôt :
   `vagrant provision <node>` la réécrit.
2. **`VRRP_ROUTER_ID` divergent** — les nodes ont été provisionnés avec des `lab.env`
   différents. Tous les control planes d'un même cluster doivent partager le même ID.
3. **Un autre lab keepalived sur le même réseau host-only avec le même ID** (défaut `51`). Deux
   groupes de même `virtual_router_id` se battent pour la VIP. Change `VRRP_ROUTER_ID` dans
   `lab.env`, puis `vagrant provision`.

> ℹ️ Il n'y a **aucun** mot de passe VRRP, et c'est volontaire : l'authentification VRRPv2 le
> transmet en clair et n'apporte rien. La frontière de confiance est le réseau host-only ; le
> bouton d'isolation, c'est `VRRP_ROUTER_ID`.

---

## ☸️ 3. Nodes et kubeadm

### Les nodes restent `NotReady`

```
NAME      STATUS     ROLES           AGE   VERSION
k8s-cp1   NotReady   control-plane   2m    v1.36.3
k8s-w1    NotReady   worker          1m    v1.36.3
```

**C'est NORMAL entre `kubeadm/cluster-up.sh` et `_k8s/platform-up.sh`.** kubeadm n'installe
aucun CNI, et un node sans réseau pod ne passe jamais `Ready`. `cluster-up.sh` le dit lui-même
dans sa bannière de fin.

Confirme le diagnostic plutôt que de le supposer :

```bash
kubectl describe node k8s-cp1 | sed -n '/Conditions:/,/Addresses:/p'
```

La condition `Ready` vaut `False`, avec pour raison `KubeletNotReady` et un message contenant :

```
container runtime network not ready: NetworkReady=false reason:NetworkPluginNotReady
message:Network plugin returns error: cni plugin not initialized
```

**Correctif :** lance l'étape suivante.

```bash
./_k8s/platform-up.sh
```

Avec `CNI=none`, personne n'installera jamais de réseau — c'est le sens du réglage, et
`cluster-up.sh` affiche alors un message de fin différent.

Si les nodes sont **toujours** `NotReady` après l'installation du CNI :

```bash
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system logs ds/cilium --tail=50
kubectl -n kube-system logs deploy/cilium-operator --tail=50
```

### CoreDNS reste `Pending`

```
kube-system   coredns-xxxxxxxxx-aaaaa   0/1   Pending   0   3m
kube-system   coredns-xxxxxxxxx-bbbbb   0/1   Pending   0   3m
```

**Même cause : il n'y a pas encore de CNI.** Tous les nodes portent le taint
`node.kubernetes.io/not-ready`, que CoreDNS ne tolère pas : le scheduler n'a nulle part où le
poser.

```bash
kubectl -n kube-system describe pod -l k8s-app=kube-dns | sed -n '/Events:/,$p'
# FailedScheduling … node(s) had untolerated taint {node.kubernetes.io/not-ready: }
```

CoreDNS se planifie dès que le premier node passe `Ready`. Rien à corriger : lance
`./_k8s/platform-up.sh`. Si CoreDNS reste `Pending` **après** que les nodes soient `Ready`,
cherche alors de vraies contraintes de placement (`WORKERS=0` avec `UNTAINT_CP=false`, par
exemple, ne laisse aucun endroit où planifier).

### Tous les nodes ont la même IP, `10.0.2.15`

```bash
kubectl get nodes -o wide
# NAME      INTERNAL-IP   …
# k8s-cp1   10.0.2.15     …
# k8s-w1    10.0.2.15     …
# k8s-w2    10.0.2.15     …
```

**Cause.** Chaque VM a deux cartes : **NIC1 = NAT VirtualBox** (toujours `10.0.2.15`,
*identique sur toutes les VM*) et **NIC2 = host-only** (la vraie adresse du cluster). Sans
`kubeletExtraArgs: node-ip`, le kubelet prend l'interface de la route par défaut — la NAT — et
tous les nodes s'enregistrent avec la même adresse. `kubectl get nodes` a l'air correct, mais
les logs, `kubectl exec`, les probes et le trafic inter-node partent au mauvais endroit.

Ce lab pose `node-ip` dans les trois modèles kubeadm : tu ne rencontres donc ce cas que si un
node a été joint **à la main** avec la ligne `kubeadm join` imprimée — cette ligne ne sait pas
transporter `node-ip`, et `kubeadm join` n'a pas de drapeau équivalent. C'est exactement pour ça
que le lab joint ses nodes par des fichiers `JoinConfiguration`.

```bash
# Ce que le kubelet a réellement reçu
vagrant ssh k8s-w1 -c "cat /var/lib/kubelet/kubeadm-flags.env"
# attendu : KUBELET_KUBEADM_ARGS="… --node-ip=192.168.56.101 …"
```

**Correctif.** Le chemin supporté est de refaire la jonction par le dépôt :

```bash
./kubeadm/cluster-reset.sh && ./kubeadm/cluster-up.sh
```

Pour réparer un seul node sans toucher au reste : édite
`/var/lib/kubelet/kubeadm-flags.env` pour y ajouter `--node-ip=<IP host-only>`, puis
`sudo systemctl restart kubelet`. Si `INTERNAL-IP` ne change pas, supprime l'objet `Node`
(`kubectl delete node k8s-w1`) pour que le kubelet se réenregistre de zéro.

### `kubeadm join` échoue sur un token expiré ou une clé de certificats invalide

Trois messages distincts, trois durées de vie :

| Message (extrait) | Ce qui a expiré | Durée de vie |
|---|---|---|
| `couldn't validate the identity of the API Server: could not find a JWS signature in the cluster-info ConfigMap for token ID` | le token de bootstrap | **24 h** |
| `error downloading certs: … Secret "kubeadm-certs" was not found in the "kube-system" Namespace` | la clé de certificats (le Secret disparaît avec elle) | **2 h** |
| `error decoding certificate key` / échec de déchiffrement | la clé de certificats ne correspond pas au Secret | **2 h** |

**Cause.** `kubeadm init` imprime un token valable 24 heures et une clé de certificats valable
**deux heures seulement**. Toute jonction après cette fenêtre échoue avec une erreur opaque.

**Correctif — le simple.** Relance le script de bootstrap : il est idempotent, et
`kubeadm/node-init.sh` **régénère systématiquement les deux éléments** avant de réécrire
`_out/join.env`. Joindre un node des heures ou des jours après le `init` initial est donc un
chemin supporté.

```bash
./kubeadm/cluster-up.sh
```

**Correctif — à la main,** si tu pilotes kubeadm toi-même :

```bash
vagrant ssh k8s-cp1 -c "sudo kubeadm init phase upload-certs --upload-certs \\
     --config /vagrant/_out/kubeadm-init.yaml"                                  # nouvelle clé de certificats
vagrant ssh k8s-cp1 -c "sudo kubeadm token create --print-join-command"        # nouveau token + empreinte CA
```

Les deux commandes sont rejouables sans risque sur un cluster en route.

### `upload-certs` échoue sur `x509: … not 10.0.2.15`

```
error execution phase upload-certs: could not bootstrap the admin user in file admin.conf:
unable to create ClusterRoleBinding: Post "https://10.0.2.15:6443/apis/rbac.authorization.k8s.io/v1/…":
tls: failed to verify certificate: x509: certificate is valid for 10.96.0.1, 192.168.56.10,
192.168.56.5, …, 127.0.0.1, not 10.0.2.15
```

**Symptôme.** `kubeadm init` réussit, la commande de jonction s'affiche, puis `cluster-up.sh`
meurt sur « impossible d'extraire les éléments de jonction ».

**Cause.** `kubeadm init phase upload-certs` construit son client API à partir de
`InitConfiguration.LocalAPIEndpoint.AdvertiseAddress` — et **non** du `controlPlaneEndpoint`, ni
de `admin.conf`. Lancée sans `--config`, la commande applique les défauts de kubeadm, qui
*détectent* cette adresse depuis la route par défaut : dans une VM Vagrant, celle-ci sort par la
carte NAT, soit `10.0.2.15`, la même sur toutes les machines. Le client vise donc une adresse
légitimement absente des SAN du certificat, et la vérification TLS échoue.

C'est le piège `node-ip` du §9, sous un autre déguisement.

**Correctif.** Déjà appliqué : `node-init.sh` passe `--config`, si bien que l'endpoint est la
vraie IP host-only du node. Si tu rencontres cette erreur, ta copie est antérieure au correctif —
`git pull`, puis relance `./kubeadm/cluster-up.sh` (il saute le `init` déjà fait et ne refait
que ce qui manque).

> ⚠️ **Ne « corrige » surtout pas en ajoutant `10.0.2.15` aux `certSANs`.** Cette adresse est
> partagée par toutes les VM du lab : elle n'identifie aucun node. Ce serait masquer un client
> pointé sur la mauvaise interface. C'est l'endpoint qu'il faut corriger, jamais le certificat.

### Le preflight kubeadm se plaint du swap, du nombre de CPU ou de la mémoire

```
[ERROR Swap]: swap is enabled; production deployments should disable swap …
[ERROR NumCPU]: the number of available CPUs 1 is less than the required 2
[ERROR Mem]: the system RAM (1024 MB) is less than the minimum 1700 MB
```

**Swap.** `kubeadm/provision.sh` s'en occupe déjà : `swapoff -a`, mise en commentaire de la
ligne de swap dans `/etc/fstab`, **et** masquage de toute unité systemd de swap (Debian 13 peut
fournir du swap par une unité que `/etc/fstab` ne décrit pas — c'est comme ça qu'il revient
après un reboot). Si l'erreur apparaît quand même, le provisioning n'a pas tourné, ou pas fini :

```bash
vagrant ssh k8s-cp1 -c "free -m ; swapon --show ; systemctl list-unit-files --type=swap"
vagrant provision k8s-cp1
```

> ℹ️ NodeSwap est GA depuis 1.34, mais `failSwapOn` vaut toujours `true` par défaut : le kubelet
> refuse de démarrer avec du swap actif tant qu'on ne le configure pas explicitement. Sur un
> lab, couper le swap est le chemin le plus court et le mieux testé.

**CPU et mémoire.** Les seuils sont ceux de kubeadm : **2 vCPU** et **~1700 Mio** sur un control
plane. Les défauts du dépôt (`CP_MEM=3072`, `CP_CPU=2`, `WK_MEM=2048`, `WK_CPU=2`) les
franchissent — on ne tombe donc là-dessus qu'après les avoir baissés dans `lab.env`. `2048`
démarre mais ne laisse qu'environ 350 Mio de marge à un etcd empilé ; `_k8s/observability/`
réclame `4096`.

```bash
# après édition de lab.env, les ressources ne changent qu'au redémarrage de la VM
vagrant reload k8s-cp1
```

### Un avertissement de preflight sur `RuntimeConfig` ou le cgroup driver

Un **avertissement** (pas une erreur) t'annonçant que kubeadm n'a pas pu lire le cgroup driver
auprès du runtime de conteneurs et se rabat sur le champ `cgroupDriver` de
`KubeletConfiguration`.

**Cause.** Seule la branche containerd **2.x** implémente la méthode CRI `RuntimeConfig` dont
kubeadm se sert pour demander au runtime quel cgroup driver il utilise. Debian 13 fournit
containerd **1.7.24**, qui ne l'aura jamais : le backport a été refusé en amont
(containerd#11346, fermé sans merge).

```bash
vagrant ssh k8s-cp1 -c "containerd --version"
vagrant ssh k8s-cp1 -c "sudo grep SystemdCgroup /etc/containerd/config.toml"   # doit valoir true
```

- Avec `CONTAINERD_SOURCE=docker` (le défaut), tu obtiens containerd 2.x du dépôt Docker et
  l'avertissement disparaît.
- Avec `CONTAINERD_SOURCE=debian`, tu obtiens containerd 1.7 et l'avertissement est attendu. Il
  est sans conséquence **en 1.36**, parce que le repli `cgroupDriver` existe encore et que le
  lab le règle sur `systemd`. Ce repli **disparaît en 1.37** — le même montage échoue alors au
  lieu d'avertir — et le champ `cgroupDriver` lui-même est retiré en 1.38.
  `CONTAINERD_SOURCE=debian` est fait pour un lab hors-ligne, et c'est une impasse pour les
  montées de version.

> ⚠️ Ce qui compte vraiment, c'est `SystemdCgroup = true` dans `/etc/containerd/config.toml`.
> Debian 13 est en cgroup v2 avec systemd comme gestionnaire ; laisser containerd sur
> `cgroupfs`, c'est deux gestionnaires qui se disputent la même hiérarchie et des nodes
> instables sous charge.

---

## 🔌 4. Réseau des pods et Services

### Après un `cluster-reset.sh`, le réseau pod se comporte de façon inexplicable

**Symptômes.** Les pods obtiennent des IP mais le trafic inter-node meurt ; le DNS échoue alors
que `ping 1.1.1.1` marche ; l'agent Cilium se plaint de maps BPF préexistantes ou d'un datapath
qu'il n'a pas créé.

**Cause.** `kubeadm reset` laisse volontairement derrière lui ce qu'il n'a pas posé : les
interfaces CNI, les **programmes eBPF épinglés**, et les règles iptables de kube-proxy. Un
`kubeadm init` suivant hérite alors d'un datapath fantôme.

`kubeadm/node-reset.sh` est ce ménage, et `cluster-reset.sh` le lance sur chaque node. Il :

- supprime `/etc/cni/net.d/*` ;
- détruit `cilium_host`, `cilium_net`, `cilium_vxlan`, `flannel.1`, `cni0`, `vxlan.calico`,
  `kube-ipvs0`, plus toutes les interfaces `lxc*` et `cali*` ;
- retire les programmes eBPF épinglés sous `/sys/fs/bpf/tc/globals/cilium_*` ;
- vide les chaînes iptables `KUBE-`/`CILIUM_`/`cali-` et purge IPVS ;
- efface `/var/lib/etcd`, `/var/lib/cni`, `/run/flannel` et redémarre containerd.

Vérifie à la main ce qui reste sur un node suspect :

```bash
vagrant ssh k8s-w1 -c "ip -o link show | grep -E 'cilium|lxc|flannel|cali|cni0'"
vagrant ssh k8s-w1 -c "sudo ls /sys/fs/bpf/tc/globals/ 2>/dev/null"
vagrant ssh k8s-w1 -c "sudo iptables-save | grep -cE 'KUBE-|CILIUM_|cali-'"
vagrant ssh k8s-w1 -c "ls -la /etc/cni/net.d/"
```

Quoi que ce soit de non vide sur un node censé être remis à zéro signifie que le ménage n'est
pas allé au bout — le script affiche `reset partiel sur <node> — poursuite` et continue au lieu
de s'arrêter. Relance-le sur ce node seul :

```bash
vagrant ssh k8s-w1 -c "sudo bash /vagrant/kubeadm/node-reset.sh"
```

Dans le doute, `vagrant destroy -f && vagrant up` est la table rase garantie : une VM neuve n'a
aucun résidu par construction.

> ℹ️ `cluster-reset.sh` est aussi le bon outil quand on veut changer `POD_CIDR`,
> `SERVICE_CIDR`, le CNI ou la VIP : tous les quatre sont figés au `kubeadm init` et ne se
> changent pas sur un cluster en route.

### Un Service `LoadBalancer` reste `<pending>`

```bash
kubectl -n envoy-gateway-system get svc
# TYPE           EXTERNAL-IP   …
# LoadBalancer   <pending>     …
```

**Cause 1 — le CNI n'est pas Cilium.** Dans ce lab, seul Cilium distribue des IP de Service
(annonce L2/ARP). Calico ne sait le faire qu'en BGP, et il n'y a aucun routeur pair sur un
réseau host-only (MetalLB requis) ; flannel et `none` ne font rien du tout.
`_k8s/platform-up.sh` le dit explicitement à l'exécution, et il retire le
`loadBalancerClass: io.cilium/l2-announcer` propre à Cilium pour qu'un autre annonceur puisse
prendre le relais.

```bash
sed -n 's/^CNI=//p' _out/cluster.env      # avec quoi le cluster a RÉELLEMENT été monté
```

> ⚠️ `_out/cluster.env` dit la vérité (écrit au bootstrap) ; `lab.env` n'exprime qu'une
> *intention* et a pu être édité après coup.

**Cause 2 — le pool L2 est absent, épuisé, ou annoncé sur la mauvaise interface.**

```bash
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
kubectl -n kube-system logs deploy/cilium-operator --tail=50
sed -n 's/^HOSTONLY_IF=//p' _out/cluster.env
```

Le pool va de `192.168.56.200` à `.230` par défaut (`LB_POOL_START`/`LB_POOL_END`), et
l'interface d'annonce vient du `HOSTONLY_IF` **détecté**, pas d'un nom codé en dur. Un pool qui
chevauche la plage des nodes, ou une politique d'annonce épinglée sur une interface
inexistante, produisent tous deux un `<pending>` définitif.

Changer le pool tient en une relance :

```bash
./_k8s/cilium/cilium-up.sh
```

---

## 🗄️ 5. etcd et performances du cluster

### etcd perd son leader, ou tout le cluster rame

**Symptômes.**

```
etcdserver: request timed out
apply request took too long
waiting for ReadIndex response took too long, retrying
leader changed
```

`kubectl` met des secondes à répondre, les pods restent `Pending`, l'apiserver redémarre tout
seul.

```bash
kubectl get --raw='/healthz/etcd'
kubectl -n kube-system logs -l component=etcd --tail=50
vagrant ssh k8s-cp1 -c "sudo crictl logs \$(sudo crictl ps -q --name etcd | head -1) 2>&1 | tail -40"
vagrant ssh k8s-cp1 -c "free -m ; uptime"
```

**Causes, par fréquence sur ce lab :**

1. **Latence de fsync.** etcd écrit chaque transaction sur disque avant de l'acquitter. Sur
   VirtualBox, un disque de VM sur un plateau mécanique — ou sur un SSD déjà saturé par l'hôte —
   pousse le fsync au-delà de ce qu'etcd tolère, et l'élection de leader se met à osciller.
   **Garde les disques des VM sur un SSD**, et ne lance pas une topologie à 3 control planes à
   côté d'un gros build.
2. **`CP_MEM` trop bas.** Un etcd empilé sur un control plane à 2048 Mio dispose d'environ
   350 Mio de marge ; les premiers addons `_k8s/` la mangent. `3072` est le vrai plancher,
   `_k8s/observability/` réclame `4096`.
3. **Dérive d'horloge.** etcd y est très sensible. Le `Vagrantfile` abaisse déjà le seuil de
   resynchronisation des additions invité à 1000 ms, ce qui couvre un cycle
   suspension/reprise — mais une VM restée suspendue longtemps gagne à être relancée :
   ```bash
   vagrant reload k8s-cp1
   ```

> ⚠️ Avec 3 control planes, etcd tolère **une** panne. N'en arrête pas deux en même temps (y
> compris pendant une montée de version — cf. [`kubeadm/MISE-A-JOUR.md`](kubeadm/MISE-A-JOUR.md)) :
> l'API se fige jusqu'au retour du quorum.

---

## 🔐 6. Les UI du lab en HTTPS

### Une UI HTTPS est injoignable

Descends la chaîne dans cet ordre — chaque étape suppose la précédente.

**1. Le Gateway a-t-il une IP ?**

```bash
kubectl -n envoy-gateway-system get gateway main-gateway -o jsonpath='{.status.addresses[0].value}'; echo
```

Vide ou `<pending>` → c'est un problème de LoadBalancer, cf. section 4. L'adresse attendue est
la **première IP de la plage**, `192.168.56.200` par défaut.

**2. Le nom résout-il vers cette IP ?**

Le domaine du lab (`LAB_DOMAIN`, `kubeadm.lab.example.io` par défaut) n'a aucune raison de
résoudre sur ta machine. `_k8s/platform-up.sh` affiche la ligne à ajouter :

```bash
# /etc/hosts sur l'HÔTE
192.168.56.200  argo.kubeadm.lab.example.io grafana.kubeadm.lab.example.io vault.kubeadm.lab.example.io
```

… ou un enregistrement `A` wildcard `*.<LAB_DOMAIN> → 192.168.56.200` si tu as une zone DNS.
Vérification :

```bash
getent hosts argo.kubeadm.lab.example.io
ping -c1 192.168.56.200
```

> ⚠️ Sur le chemin ACME (`SELF_SIGNED=false`) derrière Cloudflare, l'enregistrement doit être en
> **DNS-only (nuage GRIS)** : le proxy Cloudflare ne peut pas joindre une IP privée.

**3. Existe-t-il une `HTTPRoute` pour ce nom d'hôte ?**

```bash
kubectl get httproute -A
kubectl -n <ns> describe httproute <nom> | sed -n '/Status:/,$p'   # Accepted / ResolvedRefs
```

**4. Le mode TLS est-il celui que tu crois ?**

```bash
sed -n 's/^SELF_SIGNED=//p' lab.env
kubectl -n envoy-gateway-system get secret | grep wildcard
```

| Mode | Comportement attendu |
|---|---|
| `SELF_SIGNED=true` (défaut) | une **AC locale** signe le wildcard ; le navigateur avertit tant que `_out/self-signed/ca.crt` n'est pas importée. cert-manager n'est pas installé. |
| `SELF_SIGNED=false`, `LAB_ACME_ISSUER=staging` | Let's Encrypt **staging** : le certificat est réel mais **non trusté** — l'avertissement du navigateur est attendu. |
| `SELF_SIGNED=false`, `LAB_ACME_ISSUER=prod` | publiquement trusté — mais limité à **5 certificats par semaine** pour un `*.<LAB_DOMAIN>` donné. |

Un avertissement de navigateur est donc *normal* dans deux modes sur trois. Pour faire confiance
à l'AC locale :

```bash
sudo cp _out/self-signed/ca.crt /usr/local/share/ca-certificates/vagrant-kubeadm-lab.crt
sudo update-ca-certificates
```

**5. Toujours rien ?** Regarde le proxy lui-même :

```bash
kubectl -n envoy-gateway-system get pods
kubectl -n envoy-gateway-system logs deploy/envoy-gateway --tail=50
```

---

## 🧰 7. Boîte à outils

### Depuis l'hôte

```bash
vagrant status                       # quelles VM existent et tournent
vagrant ssh k8s-cp1                  # shell interactif
vagrant ssh k8s-cp1 -c "<commande>" -- -q -o LogLevel=ERROR   # un coup, silencieux (ce qu'utilisent les scripts)
vagrant provision k8s-cp1            # rejoue provision.sh (idempotent)
vagrant reload k8s-cp1               # redémarre en appliquant les CPU/RAM de lab.env

export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl get --raw='/readyz?verbose'

cat _out/cluster.env                 # avec quoi le cluster a RÉELLEMENT été monté
```

> ⚠️ `_out/join.env` contient le **token de jonction et la clé de certificats**. `_out/` est
> gitignoré, mais il est lisible par toutes les VM à travers le dossier synchronisé `/vagrant`.
> N'en recopie jamais le contenu nulle part.

### Dans une VM

```bash
cat /etc/kubeadm-lab/node.env                 # rôle, IP du node, interface host-only détectée
ip -4 addr show                               # la VIP est-elle ici ?
sudo systemctl status kubelet containerd keepalived

sudo journalctl -u kubelet -f                 # suivre en direct
sudo journalctl -u kubelet -n 100 --no-pager
sudo journalctl -u containerd -n 50 --no-pager
sudo journalctl -u keepalived -n 50 --no-pager

sudo crictl ps -a                             # conteneurs, y compris morts
sudo crictl pods                              # sandboxes
sudo crictl logs <id-conteneur>
sudo crictl images

sudo kubeadm certs check-expiration           # control planes uniquement
sudo kubeadm config images list --kubernetes-version v1.36.3
```

> 💡 `crictl` parle au même socket que le kubelet grâce à `/etc/crictl.yaml`, écrit par
> `provision.sh`. Sans lui, `crictl` part chercher dockershim et affiche des erreurs
> déroutantes.

### Les options radicales, de la plus douce à la plus destructrice

| Commande | Ce qu'elle détruit | Quand |
|---|---|---|
| `vagrant provision <node>` | rien | réappliquer les prérequis système |
| `./kubeadm/cluster-up.sh` | rien (idempotent) | rejouer un bootstrap partiel, ajouter des nodes |
| `./kubeadm/cluster-reset.sh` | etcd, les certificats, toutes les charges — **garde les VM** | changer `POD_CIDR`, `SERVICE_CIDR`, le CNI ou la VIP |
| `vagrant destroy -f && vagrant up` | tout | le moindre doute sur un résidu système |

---

## 📚 Références

- [kubeadm — Troubleshooting](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/troubleshooting-kubeadm/)
- [kubeadm — Configuring a cgroup driver](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/configure-cgroup-driver/)
- [Kubernetes — Debugging DNS resolution](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)
- [Cilium — Troubleshooting](https://docs.cilium.io/en/stable/operations/troubleshooting/)
- [etcd — Tuning](https://etcd.io/docs/latest/tuning/)
- [`kubeadm/MISE-A-JOUR.md`](kubeadm/MISE-A-JOUR.md) — montées de version et renouvellement des certificats
