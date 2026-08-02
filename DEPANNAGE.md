<!-- i18n -->
[English](TROUBLESHOOTING.md) · **Français**
<!-- /i18n -->

# 🚑 Dépannage

> Organisé par **symptôme observé**, parce que c'est ce qu'on a sous les yeux : un message
> d'erreur, pas une théorie. Parcours d'installation : [`LISEZ-MOI.md`](LISEZ-MOI.md) · couche
> applicative : <https://ops-nc.github.io/k8s-playground/> · montées de version :
> [`kubeadm/MISE-A-JOUR.md`](kubeadm/MISE-A-JOUR.md).

Cette page couvre le lab lui-même : l'hôte, VirtualBox, keepalived, kubeadm et les nodes Debian.
Les problèmes d'addons (Longhorn, Vault, Calico…) sont documentés avec les addons, dans
[k8s-playground](https://ops-nc.github.io/k8s-playground/).

Sauf mention contraire, les commandes se lancent **depuis la racine du dépôt**, avec
`export KUBECONFIG="$PWD/kubeconfig"`.

---

## 🖥️ 1. Hôte, dépôt et VirtualBox

### `vagrant up` meurt sur `VERR_VMX_IN_VMX_ROOT_MODE`

```
VBoxManage: error: VT-x is being used by another hypervisor (VERR_VMX_IN_VMX_ROOT_MODE).
```

VirtualBox et KVM ne peuvent pas détenir **VT-x** en même temps, et la plupart des distributions
Linux chargent KVM au démarrage.

```bash
lsmod | grep kvm                    # Intel : kvm_intel — AMD : kvm_amd
sudo modprobe -r kvm_intel kvm      # échoue si une VM KVM/libvirt tourne encore
```

> 💡 KVM revient à chaque démarrage. Si cet hôte ne fait jamais de KVM/libvirt, blackliste-le une
> fois :
> ```bash
> echo -e "blacklist kvm_intel\nblacklist kvm" | sudo tee /etc/modprobe.d/disable-kvm.conf
> ```

### VirtualBox refuse le réseau host-only `192.168.56.0/24`

VirtualBox 7 n'autorise que les plages host-only explicitement permises :

```
# /etc/vbox/networks.conf
* 192.168.56.0/21
```

Tout le lab vit dans ce `/24` — nodes, VIP `.5`, pool LoadBalancer `.200`–`.230` — donc rien ne
fonctionne avant que VirtualBox l'accepte.

### `vagrant up` refuse un nombre pair de control planes

```
Vagrant-KubeADM: CONTROL_PLANES=2 is EVEN — etcd requires an odd number to hold a
useful quorum (1, 3, 5). With 2 members, losing a single node freezes the API.
```

Un garde-fou, pas un bug : etcd tient son quorum à `(n/2)+1`, donc deux membres ne tolèrent
**aucune** panne tout en coûtant deux fois un seul. Utilise `1`, `3` ou `5`. Le `Vagrantfile`
refuse aussi une IP de node qui collisionne avec `.1`, `.2`, `.100` ou la VIP, et refuse les
doublons ; chaque erreur nomme la variable fautive.

### `_k8s/` est vide — `./_k8s/platform-up.sh: No such file or directory`

`_k8s/` est un **sous-module git**. Un `git clone` simple l'enregistre mais ne le sort pas.

```bash
git submodule update --init --recursive     # remplit _k8s/
git -C _k8s log --oneline -1                # contrôle rapide
```

La prochaine fois, clone correctement : `git clone --recurse-submodules <url>`. `git pull` ne met
pas non plus le sous-module à jour — répète la commande ci-dessus après chaque pull, ou
`git submodule update --remote _k8s` pour sauter au dernier commit amont.

### Les scripts `_k8s/` ne trouvent ni `lab.env` ni le kubeconfig

Symptômes : les addons s'installent sur le **mauvais domaine** (`lab.example.io` au lieu de ton
`LAB_DOMAIN`), le **mauvais CNI** est choisi, ou `kubectl` échoue dans les scripts sur
`connection refused`. La bannière affichée au démarrage indique `lab.env: absent (defaults)`.

Le lab n'a pas été localisé. k8s-playground n'a pas de `Vagrantfile` : il prend comme lab le
dossier qui *contient* `_k8s/`, à condition que ce dossier porte un `Vagrantfile` — c'est là que
vivent `lab.env`, `_out/` et `kubeconfig`. Le même parcours décide de la distribution
(`kubeadm/cluster-up.sh` à côté du `Vagrantfile` = lab kubeadm), donc un lab non trouvé signifie
aussi une distribution non détectée.

```bash
ls Vagrantfile lab.env kubeadm/cluster-up.sh   # marqueur, config, signature de distro
ls -d _k8s/lib                                 # _k8s/ est bien DANS le lab
```

Causes typiques : `_k8s/` cloné seul ailleurs, un `lab.env` jamais créé depuis
`lab.env.example`, ou des scripts appelés par un lien symbolique qui sort du lab. Le pointeur
explicite gagne toujours sur la détection :

```bash
LAB_DIR=/chemin/vers/Vagrant-kubeadm ./_k8s/platform-up.sh
```

> 💡 `LAB_ENV=/chemin/vers/lab.env` fait pareil quand le fichier est ailleurs ou nommé
> autrement. `LAB_DIR` est celui à retenir : il pilote `lab.env`, `_out/cluster.env` **et** le
> `KUBECONFIG` par défaut d'un coup.

---

## 🌐 2. La VIP de l'API et keepalived

### `cluster-up.sh` échoue sur « l'apiserver ne répond pas sur la VIP »

```
    - waiting for https://192.168.56.5:6443 ....................... FAILED (600s)
ERROR: the apiserver does not answer on the VIP 192.168.56.5 after 600s.
```

`kubeadm init` a déjà tourné : le script attend `/readyz` **à travers la VIP**, l'adresse que tous
les autres nodes utiliseront pour joindre. Deux causes, par fréquence.

**Cause 1 — keepalived ne porte pas la VIP.**

```bash
vagrant ssh k8s-cp1 -c "ip -4 addr show | grep 192.168.56.5"
vagrant ssh k8s-cp1 -c "sudo systemctl status keepalived"
vagrant ssh k8s-cp1 -c "sudo journalctl -u keepalived -n 50 --no-pager"
```

| Observation | Signification |
|---|---|
| rien pour `.5` | aucun node ne porte la VIP |
| `keepalived.service: failed`, `Cant find interface` | keepalived a été configuré sur la mauvaise interface |
| `Entering BACKUP STATE` sur tous les control planes | les pairs se voient mais personne ne se promeut |

L'interface est **détectée**, jamais codée en dur — vérifie ce que `provision.sh` a trouvé :

```bash
vagrant ssh k8s-cp1 -c "cat /etc/kubeadm-lab/node.env"
vagrant ssh k8s-cp1 -c "sudo sed -n '/vrrp_instance/,\$p' /etc/keepalived/keepalived.conf"
```

Si `HOSTONLY_IF` est retombé sur `eth1` alors que la VM utilise vraiment `enp0s8`, keepalived
s'attache à une interface qui n'existe pas. Relance `vagrant provision k8s-cp1` une fois que la VM
a son adresse host-only.

**Cause 2 — l'apiserver lui-même ne démarre pas.**

```bash
vagrant ssh k8s-cp1 -c "sudo crictl ps -a | grep apiserver"
vagrant ssh k8s-cp1 -c "sudo journalctl -u kubelet -n 50 --no-pager"
vagrant ssh k8s-cp1 -c "sudo crictl logs \$(sudo crictl ps -a -q --name kube-apiserver | head -1)"
```

Un apiserver en `CrashLoopBackOff`, c'est presque toujours etcd en dessous — voir la section 5. À
noter : le contrôle de santé de keepalived ne retire que 30 points de priorité, jamais la VIP,
donc **la VIP debout ne prouve rien sur l'apiserver.**

### La VIP est portée par DEUX nodes à la fois (split-brain VRRP)

`kubectl` se comporte de façon erratique — une requête passe, la suivante expire — et le journal
affiche `Entering MASTER STATE` sur deux nodes.

```bash
for n in k8s-cp1 k8s-cp2 k8s-cp3; do
  echo -n "$n: " ; vagrant ssh "$n" -c "ip -4 -o addr show | grep -c 192.168.56.5" -- -q
done
# sain : exactement un node répond 1, les autres 0
```

VRRP est ici en **unicast** (`unicast_src_ip` + `unicast_peer`), pas en multicast, parce que le
multicast est la première chose à mal se comporter sur un switch host-only VirtualBox. Un control
plane qui ne voit pas ses pairs se croit seul et se promeut.

```bash
# la liste des pairs doit contenir toutes les AUTRES IP de control plane
vagrant ssh k8s-cp1 -c "sudo sed -n '/unicast/,/}/p' /etc/keepalived/keepalived.conf"

# le router ID doit être IDENTIQUE sur tous les control planes
for n in k8s-cp1 k8s-cp2 k8s-cp3; do
  vagrant ssh "$n" -c "sudo sed -n 's/.*virtual_router_id //p' /etc/keepalived/keepalived.conf" -- -q
done
```

Trois causes, par ordre de probabilité :

1. **Un bloc `unicast_peer` manquant** — keepalived ne rejette pas une telle config, il retombe en
   silence sur le multicast, et les deux modes sont *mutuellement sourds*.
   `vagrant provision <node>` la réécrit (la config liste toujours les cinq IP de control plane que
   le plan d'adressage autorise, donc une config écrite pour un CP est déjà correcte pour trois).
2. **`VRRP_ROUTER_ID` divergent** — nodes provisionnés avec des `lab.env` différents. Tous les
   control planes d'un cluster doivent partager le même ID.
3. **Un autre lab keepalived sur le même réseau host-only avec le même ID** (défaut `51`). Change
   `VRRP_ROUTER_ID`, puis `vagrant provision`.

> ℹ️ Il n'y a volontairement aucun mot de passe VRRP : l'authentification VRRPv2 l'envoie en clair
> et n'apporte rien. La frontière de confiance est le réseau host-only ; le bouton d'isolation est
> `VRRP_ROUTER_ID`.

---

## ☸️ 3. Nodes et kubeadm

### Les nodes restent `NotReady`, CoreDNS reste `Pending`

```
NAME      STATUS     ROLES           AGE   VERSION
k8s-cp1   NotReady   control-plane   2m    v1.36.3
k8s-w1    NotReady   worker          1m    v1.36.3
```

**Normal entre `cluster-up.sh` et l'étape plateforme.** kubeadm n'installe pas de CNI, et un node
sans réseau de pods ne passe jamais `Ready`. CoreDNS suit : chaque node porte le taint
`node.kubernetes.io/not-ready`, qu'il ne tolère pas.

```bash
kubectl describe node k8s-cp1 | sed -n '/Conditions:/,/Addresses:/p'
# Ready False — KubeletNotReady — cni plugin not initialized
```

Remède : `./_k8s/platform-up.sh`. Avec `CNI=none`, rien n'installera jamais de réseau — c'est le
sens du réglage, et `cluster-up.sh` affiche un message de fin différent dans ce cas.

Toujours `NotReady` après l'installation du CNI, ou CoreDNS toujours `Pending` après que les nodes
sont `Ready` :

```bash
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system logs ds/cilium --tail=50
kubectl -n kube-system logs deploy/cilium-operator --tail=50
```

`WORKERS=0` avec `UNTAINT_CP=false` ne laisse également nulle part où planifier.

### Tous les nodes affichent la même IP, `10.0.2.15`

```
# NAME      INTERNAL-IP
# k8s-cp1   10.0.2.15
# k8s-w1    10.0.2.15
```

Chaque VM a deux cartes : NIC1 = NAT VirtualBox (toujours `10.0.2.15`, *identique sur toutes les
VM*) et NIC2 = host-only (la vraie adresse du cluster). Sans `kubeletExtraArgs: node-ip`, le
kubelet prend l'interface de la route par défaut — celle du NAT. `kubectl get nodes` paraît
crédible, mais les logs, `exec`, les sondes et le trafic inter-nodes partent au mauvais endroit.

Le lab pose `node-ip` dans ses trois templates : tu ne rencontres donc ça que sur un node joint
**à la main** avec la ligne `kubeadm join` imprimée — cette ligne ne peut pas porter `node-ip`.

```bash
vagrant ssh k8s-w1 -c "cat /var/lib/kubelet/kubeadm-flags.env"
# attendu : KUBELET_KUBEADM_ARGS="… --node-ip=192.168.56.101 …"
```

Remède supporté : refaire la jonction par le dépôt
(`./kubeadm/cluster-reset.sh && ./kubeadm/cluster-up.sh`). Pour réparer un seul node, ajoute
`--node-ip=<IP host-only>` à `/var/lib/kubelet/kubeadm-flags.env` puis
`systemctl restart kubelet` ; si `INTERNAL-IP` ne change pas, `kubectl delete node k8s-w1` pour que
le kubelet se réenregistre.

### `kubeadm join` échoue sur un token ou une clé de certificats expirés

| Message (extrait) | Ce qui a expiré | Durée de vie |
|---|---|---|
| `could not find a JWS signature in the cluster-info ConfigMap for token ID` | le token de bootstrap | **24 h** |
| `error downloading certs: … Secret "kubeadm-certs" was not found` | la clé de certificats (le Secret est ramassé avec elle) | **2 h** |
| `error decoding certificate key` / échec de déchiffrement | la clé ne correspond pas au Secret | **2 h** |

Remède facile : relancer `./kubeadm/cluster-up.sh`. Il est idempotent, et `node-init.sh` régénère
les deux éléments à chaque passage avant de réécrire `_out/join.env` — joindre un node des jours
après l'`init` initial est un parcours supporté.

À la main, si tu conduis kubeadm toi-même (les deux se rejouent sans risque sur un cluster
vivant) :

```bash
vagrant ssh k8s-cp1 -c "sudo kubeadm init phase upload-certs --upload-certs \\
     --config /vagrant/_out/kubeadm-init.yaml"                                  # nouvelle clé
vagrant ssh k8s-cp1 -c "sudo kubeadm token create --print-join-command"        # token + hash CA
```

> ⚠️ Lance `upload-certs` **avec `--config`**. Sans lui, kubeadm construit son client d'API depuis
> un `LocalAPIEndpoint.AdvertiseAddress` qu'il détecte sur la route par défaut — `10.0.2.15` dans
> n'importe quelle VM Vagrant — et TLS échoue sur
> `x509: certificate is valid for …, not 10.0.2.15`. C'est l'endpoint qu'il faut corriger :
> n'ajoute jamais `10.0.2.15` aux `certSANs`, cette adresse n'identifie aucun node.

### Le preflight kubeadm se plaint du swap, du nombre de CPU ou de la mémoire

```
[ERROR Swap]: swap is enabled; production deployments should disable swap …
[ERROR NumCPU]: the number of available CPUs 1 is less than the required 2
[ERROR Mem]: the system RAM (1024 MB) is less than the minimum 1700 MB
```

Le **swap** est déjà traité par `provision.sh` : `swapoff -a`, la ligne `/etc/fstab` commentée,
**et** toute unité systemd de swap masquée (Debian 13 peut fournir du swap par une unité que
`/etc/fstab` ne mentionne jamais — c'est comme ça que le swap revient après un redémarrage).
L'erreur qui apparaît quand même signifie que le provisioning n'est pas allé au bout :

```bash
vagrant ssh k8s-cp1 -c "free -m ; swapon --show ; systemctl list-unit-files --type=swap"
vagrant provision k8s-cp1
```

Les seuils **CPU et mémoire** sont ceux de kubeadm : 2 vCPU et ~1700 Mio sur un control plane. Les
défauts du dépôt les passent, donc ça ne mord qu'après les avoir baissés dans `lab.env`. Les
ressources changent au redémarrage de la VM : `vagrant reload k8s-cp1`.

> ℹ️ NodeSwap est GA depuis 1.34, mais `failSwapOn` vaut toujours `true` par défaut : le kubelet
> refuse de démarrer avec du swap actif tant que tu ne le configures pas explicitement. Sur un
> lab, couper le swap est le chemin le plus court et le mieux testé.

### Un avertissement de preflight sur `RuntimeConfig` ou le pilote cgroup

Un **avertissement**, pas une erreur : kubeadm n'a pas pu lire le pilote cgroup depuis le runtime
et est retombé sur le champ `cgroupDriver` de `KubeletConfiguration`. Seul containerd **2.x**
implémente la méthode CRI `RuntimeConfig` qu'il utilise ; Debian 13 livre **1.7.24**, qui ne
l'aura jamais (backport refusé en amont, containerd#11346).

```bash
vagrant ssh k8s-cp1 -c "containerd --version"
vagrant ssh k8s-cp1 -c "sudo grep SystemdCgroup /etc/containerd/config.toml"   # doit être true
```

Avec `CONTAINERD_SOURCE=docker` (le défaut), l'avertissement disparaît. Avec
`CONTAINERD_SOURCE=debian` il est attendu — inoffensif en 1.36, **fatal en 1.37** où le repli est
retiré : cette valeur est une option pour lab hors-ligne et une impasse pour les montées de
version.

> ⚠️ Ce qui compte vraiment, c'est `SystemdCgroup = true`. Debian 13 est en cgroup v2 avec systemd
> comme gestionnaire ; laisser containerd en `cgroupfs` met deux gestionnaires en concurrence sur
> la même hiérarchie et les nodes deviennent instables sous charge.

---

## 🔌 4. Réseau de pods et Services

### Après un `cluster-reset.sh`, le réseau de pods se comporte de façon inexplicable

Les pods obtiennent des IP mais le trafic inter-nodes meurt ; le DNS échoue alors que
`ping 1.1.1.1` fonctionne ; l'agent Cilium se plaint de maps BPF préexistantes.

`kubeadm reset` laisse volontairement ce qu'il n'a pas posé : interfaces CNI, programmes eBPF
**épinglés**, et règles iptables de kube-proxy — donc un `kubeadm init` ultérieur hérite d'un
datapath fantôme. `kubeadm/node-reset.sh` est ce nettoyage et `cluster-reset.sh` le lance partout :
il retire `/etc/cni/net.d/*`, les interfaces
`cilium_*`/`flannel.1`/`cni0`/`vxlan.calico`/`kube-ipvs0`/`lxc*`/`cali*`, les programmes épinglés
sous `/sys/fs/bpf/tc/globals/cilium_*`, les chaînes `KUBE-`/`CILIUM_`/`cali-` et IPVS, puis efface
`/var/lib/etcd`, `/var/lib/cni`, `/run/flannel` et redémarre containerd.

Vérifie ce qui reste sur un node suspect :

```bash
vagrant ssh k8s-w1 -c "ip -o link show | grep -E 'cilium|lxc|flannel|cali|cni0'"
vagrant ssh k8s-w1 -c "sudo ls /sys/fs/bpf/tc/globals/ 2>/dev/null"
vagrant ssh k8s-w1 -c "sudo iptables-save | grep -cE 'KUBE-|CILIUM_|cali-'"
```

Tout ce qui n'est pas vide signifie que le nettoyage n'est pas allé au bout — le script affiche
`partial reset on <node> — carrying on` plutôt que de s'arrêter. Relance-le là :
`vagrant ssh k8s-w1 -c "sudo bash /vagrant/kubeadm/node-reset.sh"`. Dans le doute,
`vagrant destroy -f && vagrant up` est la table rase garantie.

> ℹ️ `cluster-reset.sh` est aussi le bon outil pour changer `POD_CIDR`, `SERVICE_CIDR`, le CNI ou
> la VIP : les quatre sont figés au moment du `kubeadm init`.

### Un Service `LoadBalancer` reste `<pending>`

**Cause 1 — le CNI n'est pas Cilium.** Seul Cilium distribue des IP de Service ici (annonce
L2/ARP). Calico a besoin de BGP et il n'y a pas de routeur pair sur un réseau host-only (MetalLB
requis) ; flannel et `none` ne font rien.

```bash
sed -n 's/^CNI=//p' _out/cluster.env      # avec quoi le cluster a réellement été construit
```

> ⚠️ `_out/cluster.env` est la vérité (écrit au bootstrap) ; `lab.env` n'est qu'une *intention* et
> a peut-être été édité après.

**Cause 2 — le pool L2 est absent, épuisé ou annoncé sur la mauvaise interface.**

```bash
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
kubectl -n kube-system logs deploy/cilium-operator --tail=50
sed -n 's/^HOSTONLY_IF=//p' _out/cluster.env
```

Le pool vaut `192.168.56.200`–`.230` par défaut, et l'interface d'annonce vient du `HOSTONLY_IF`
**détecté**. Un pool qui chevauche la plage des nodes, ou une politique épinglée à une interface
inexistante, donnent tous deux un `<pending>` permanent. Changer le pool tient en une relance :
`./_k8s/cilium/cilium-up.sh`.

---

## 🗄️ 5. etcd et performances du cluster

### etcd perd son leader, ou tout le cluster rampe

```
etcdserver: request timed out
apply request took too long
waiting for ReadIndex response took too long, retrying
leader changed
```

`kubectl` met des secondes à répondre, les pods restent `Pending`, l'apiserver redémarre seul.

```bash
kubectl get --raw='/healthz/etcd'
kubectl -n kube-system logs -l component=etcd --tail=50
vagrant ssh k8s-cp1 -c "free -m ; uptime"
```

Causes, par ordre de fréquence sur ce lab :

1. **Latence de fsync.** etcd valide chaque écriture sur disque avant d'accuser réception. Sous
   VirtualBox, un disque de VM sur un plateau tournant — ou sur un SSD déjà saturé par l'hôte —
   pousse le fsync au-delà de la tolérance d'etcd et l'élection de leader se met à osciller. Garde
   les disques des VM sur SSD, et ne lance pas une topologie à 3 control planes à côté d'un build
   lourd.
2. **`CP_MEM` trop bas.** Un etcd empilé sur 2048 Mio a ~350 Mio de marge ; les premiers addons la
   mangent. `3072` est le vrai plancher, `_k8s/observability/` demande `4096`.
3. **Dérive d'horloge.** etcd y est très sensible. Le `Vagrantfile` abaisse le seuil de
   synchronisation des additions invité à 1000 ms, ce qui couvre un cycle suspend/resume — mais une
   VM laissée longtemps suspendue gagne à être passée en `vagrant reload`.

> ⚠️ Avec 3 control planes, etcd tolère **une** panne. N'en arrête pas deux en même temps (y
> compris pendant une montée de version — voir [`kubeadm/MISE-A-JOUR.md`](kubeadm/MISE-A-JOUR.md)) :
> l'API gèle jusqu'au retour du quorum.

---

## 🔐 6. Les UI du lab en HTTPS

Descends la chaîne dans l'ordre — chaque étape suppose la précédente.

**1. Le Gateway a-t-il une IP ?**

```bash
kubectl -n envoy-gateway-system get gateway main-gateway -o jsonpath='{.status.addresses[0].value}'; echo
```

Vide ou `<pending>` → problème de LoadBalancer, voir la section 4. L'adresse attendue est la
première IP du pool, `192.168.56.200` par défaut.

**2. Le nom résout-il vers cette IP ?**

`LAB_DOMAIN` n'a aucune raison de résoudre sur ta machine. `platform-up.sh` affiche la ligne à
ajouter :

```bash
# /etc/hosts sur l'HÔTE
192.168.56.200  argo.kubeadm.lab.example.io grafana.kubeadm.lab.example.io
```

…ou un enregistrement `A` wildcard `*.<LAB_DOMAIN>` → `192.168.56.200` si tu possèdes une zone DNS
(en **DNS-only** derrière Cloudflare : le proxy ne peut pas joindre une IP privée).

```bash
getent hosts argo.kubeadm.lab.example.io
```

> ⚠️ **Ne teste pas l'IP du Gateway avec `ping`.** Une IP de Service annoncée en L2 par Cilium
> répond à l'**ARP** et au **TCP**, mais pas à l'ICMP — aucune interface ne porte réellement
> l'adresse. Un `ping` qui échoue sur `.200` est normal et ne prouve rien, alors que le `ping` d'un
> *node* fonctionne, ce qui rend le faux négatif convaincant. La vraie preuve de l'annonce, c'est
> l'entrée ARP qui se résout vers la MAC d'un node :
> ```bash
> sudo ip neigh flush 192.168.56.200
> curl -s -o /dev/null --max-time 5 http://192.168.56.200/    # 404 = Envoy répond
> ip neigh show 192.168.56.200                                # lladdr = le node annonceur
> ```

**3. Existe-t-il une `HTTPRoute` pour ce nom d'hôte ?**

```bash
kubectl get httproute -A
kubectl -n <ns> describe httproute <nom> | sed -n '/Status:/,$p'   # Accepted / ResolvedRefs
```

> ℹ️ Sur l'**IP nue**, `http://` répond `404` (Envoy écoute, aucune route ne correspond) mais
> `https://` ne répond rien du tout : le listener TLS est délimité par nom d'hôte, donc une requête
> sans SNI ne correspond à aucun listener. Teste avec le nom, en court-circuitant le DNS au
> besoin :
> `curl -sk --resolve argo.kubeadm.lab.example.io:443:192.168.56.200 https://argo.kubeadm.lab.example.io/`.

**4. Le mode TLS est-il celui que tu crois ?**

```bash
sed -n 's/^SELF_SIGNED=//p' lab.env
kubectl -n envoy-gateway-system get secret | grep wildcard
```

| Mode | Comportement attendu |
|---|---|
| `SELF_SIGNED=true` (défaut) | une **AC locale** signe le wildcard ; le navigateur avertit jusqu'à l'import de `_out/self-signed/ca.crt`. Aucun cert-manager installé. |
| `SELF_SIGNED=false`, `LAB_ACME_ISSUER=staging` | Let's Encrypt **staging** : certificat réel, **non fiable** — l'avertissement du navigateur est attendu. |
| `SELF_SIGNED=false`, `LAB_ACME_ISSUER=prod` | reconnu publiquement — mais limité à **5 certificats par semaine** pour un `*.<LAB_DOMAIN>` donné. |

Un avertissement de navigateur est donc *normal* dans deux modes sur trois. Pour faire confiance à
l'AC locale :

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
vagrant ssh k8s-cp1 -c "<commande>" -- -q -o LogLevel=ERROR   # one shot, silencieux (ce que font les scripts)
vagrant provision k8s-cp1            # rejoue provision.sh (idempotent)
vagrant reload k8s-cp1               # redémarre en appliquant les CPU/RAM de lab.env

export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl get --raw='/readyz?verbose'

cat _out/cluster.env                 # avec quoi le cluster a VRAIMENT été construit
```

> ⚠️ `_out/join.env` contient le **token de jonction et la clé de certificats**. `_out/` est
> gitignoré, mais lisible par toutes les VM via le dossier synchronisé `/vagrant`. Ne colle jamais
> son contenu nulle part.

### Dans une VM

```bash
cat /etc/kubeadm-lab/node.env                 # rôle, IP du node, interface host-only détectée
ip -4 addr show                               # la VIP est-elle ici ?
sudo systemctl status kubelet containerd keepalived

sudo journalctl -u kubelet -f
sudo journalctl -u containerd -n 50 --no-pager
sudo journalctl -u keepalived -n 50 --no-pager

sudo crictl ps -a                             # conteneurs, morts inclus
sudo crictl logs <container-id>

sudo kubeadm certs check-expiration           # control planes seulement
sudo kubeadm config images list --kubernetes-version v1.36.3
```

> 💡 `crictl` parle au même socket que le kubelet grâce à `/etc/crictl.yaml`, écrit par
> `provision.sh`. Sans lui, `crictl` cherche dockershim et affiche des erreurs déroutantes.

### Les options nucléaires, de la moins à la plus destructrice

| Commande | Ce qu'elle détruit | Quand |
|---|---|---|
| `vagrant provision <node>` | rien | réappliquer les prérequis système |
| `./kubeadm/cluster-up.sh` | rien (idempotent) | rejouer un bootstrap partiel, ajouter des nodes |
| `./kubeadm/cluster-reset.sh` | etcd, certificats, toutes les charges de travail — **garde les VM** | changer `POD_CIDR`, `SERVICE_CIDR`, le CNI ou la VIP |
| `vagrant destroy -f && vagrant up` | tout | doute sur un résidu au niveau système |

---

## 📚 Références

- [kubeadm — Troubleshooting](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/troubleshooting-kubeadm/)
- [kubeadm — Configuring a cgroup driver](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/configure-cgroup-driver/)
- [Cilium — Troubleshooting](https://docs.cilium.io/en/stable/operations/troubleshooting/)
- [etcd — Tuning](https://etcd.io/docs/latest/tuning/)
- [`kubeadm/MISE-A-JOUR.md`](kubeadm/MISE-A-JOUR.md) — montées de version et renouvellement des
  certificats
- [k8s-playground](https://ops-nc.github.io/k8s-playground/) — la couche applicative `_k8s/`,
  addon par addon, avec ses propres sections de pièges
