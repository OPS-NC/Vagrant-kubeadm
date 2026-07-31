<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🐆 `calico/` — CNI alternatif : réseau pod + NetworkPolicy, **sans** IP LoadBalancer

> Troisième choix de CNI du lab, à côté de `flannel` (minimaliste) et de `cilium`
> (le défaut). Calico est installé par l'**opérateur Tigera** et couvre le réseau pod,
> le routage et les NetworkPolicy. Il **ne remplace pas** le rôle de « cloud provider »
> que Cilium assure en plus : aucune IP de Service `LoadBalancer`, donc aucun VIP
> `192.168.56.200` — il faut MetalLB à côté. Lis la section 🎯 avant de choisir.

## 🎯 À quoi ça sert

### Ce que Calico fait ici

- **CNI** : réseau pod en **VXLAN** sur `10.244.0.0/16`, `natOutgoing` pour sortir vers
  Internet. C'est lui qui fait passer les nodes de `NotReady` à `Ready`.
- **NetworkPolicy** : les `networking.k8s.io/v1` standard **et** les
  `NetworkPolicy`/`GlobalNetworkPolicy` de `projectcalico.org/v3` (ordre, tiers, `deny`
  explicite, `HostEndpoint`…). C'est la vraie raison d'être de ce dossier : travailler la
  micro-segmentation avec l'implémentation de référence.
- **API `projectcalico.org/v3`** : le `calico-apiserver` est activé, donc les objets Calico
  se lisent et s'écrivent au `kubectl`, sans installer `calicoctl`.

### Ce que Calico ne fait pas — et pourquoi c'est bloquant

> ⚠️ **Calico n'annonce PAS les IP de Service `LoadBalancer` sur ce lab.** Il ne sait le
> faire qu'en **BGP** (`serviceLoadBalancerIPs` d'une `BGPConfiguration`), ce qui suppose un
> **routeur pair** avec qui établir une session. Sur un réseau host-only VirtualBox, ce
> routeur n'existe pas. Et Calico n'a **aucun équivalent** de l'annonce L2/ARP de Cilium
> (`CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy`). C'est pour ça que
> `installation.yaml` pose `bgp: Disabled` : ce n'est pas un oubli, c'est un constat.

Conséquence concrète, pas théorique : avec `CNI=calico` **et rien d'autre**,

| Ce qui se passe | Effet visible |
|---|---|
| Le Service du Gateway Envoy ne reçoit jamais d'IP externe | `EXTERNAL-IP <pending>` |
| La `Gateway` `main-gateway` n'a pas d'adresse | `status.addresses` vide |
| Les `HTTPRoute` ne sont joignables par personne | Argo CD, Grafana, Vault, Longhorn, MinIO… **inaccessibles** |
| Le certificat wildcard s'émet quand même (DNS-01) | mais ne sert à rien : plus de point d'entrée |

Autrement dit : **toute la couche `_k8s/` du lab dépend de ce VIP**. Voir
[🌐 Rendre les UI joignables](#-rendre-les-ui-du-lab-joignables-metallb) pour la marche à suivre.

### Cilium ou Calico ?

| Capacité | Cilium (`_k8s/cilium/`) | Calico (ce dossier) |
|---|---|---|
| CNI (réseau pod, routage) | ✅ VXLAN, interface host-only épinglée | ✅ VXLAN, autodétection sur `192.168.56.0/24` |
| NetworkPolicy Kubernetes | ✅ | ✅ |
| Policies étendues | ✅ `CiliumNetworkPolicy` (L7, DNS, identités) | ✅ `projectcalico.org/v3` (tiers, ordre, `HostEndpoint`) |
| **Annonce L2 des IP LoadBalancer** | ✅ intégrée (ARP, pool `.200-.230`) | ❌ **MetalLB obligatoire** (Calico = BGP uniquement) |
| Remplacement de kube-proxy | ✅ `kubeProxyReplacement=true` (documenté) | ⚠️ seulement en dataplane **eBPF**, écarté ici (cf. ⚠️ Pièges) |
| Observabilité des flux | ✅ Hubble (relay + UI) installés | ⚠️ Whisker + Goldmane livrés par le chart, **désactivés** par défaut ici |
| Prêt à l'emploi dans CE lab | ✅ `platform-up.sh` enchaîne tout | ⚠️ deux étapes manuelles restent à ta charge |

> 💡 **Recommandation : garde Cilium comme défaut du lab.** Calico est là pour *comparer*
> les CNI et pour travailler les NetworkPolicy, pas pour allumer un lab complet sans
> travail supplémentaire.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| Cluster bootstrapé **sans CNI** (`CNI=calico` dans `lab.env`, puis `./kubeadm/cluster-up.sh`) | `kubeadm init` n'installe jamais de réseau pod : Calico prend la place | `kubectl get nodes` → tous `NotReady` **avant** l'install, c'est normal |
| **Aucun autre CNI présent** | deux CNI se disputent `/etc/cni/net.d` et les routes ; pas de retour en arrière propre | le script refuse de tourner s'il voit un DaemonSet `cilium` ou `flannel` dans n'importe quel namespace |
| **`KUBE_PROXY_REPLACEMENT=false`** | ⚠️ seul Cilium sait remplacer kube-proxy ici. `kubeadm/cluster-up.sh` refuse net le couple `calico` + `true`, et ce script le revérifie : sans kube-proxy ET sans remplaçant, plus aucune ClusterIP ne répond | `kubectl -n kube-system get ds/kube-proxy` |
| `podSubnet` de kubeadm == CIDR de l'`IPPool` | sinon kubelet alloue des IP de pod que Calico n'a pas programmées | `grep POD_CIDR _out/cluster.env` → `10.244.0.0/16` |
| Adresse host-only sur chaque node | source de l'autodétection d'adresse Calico | `kubectl get nodes -o wide` → `INTERNAL-IP` en `192.168.56.x` |
| `kubectl` + `helm`, `KUBECONFIG` posé | le script vérifie les binaires puis `/readyz` | `helm version` |

## ⚡ Installation

```bash
./_k8s/calico/calico-up.sh
```

Chart `projectcalico/tigera-operator` **`v3.32.1`** (repo `https://docs.tigera.io/calico/charts`),
épinglé dans le script via `CALICO_VERSION`. Idempotent (`helm upgrade --install` +
`kubectl apply`), relançable sans casse.

Variables surchargeables :

| Variable | Défaut | Rôle |
|---|---|---|
| `CALICO_VERSION` | `v3.32.1` | version du chart **et** de Calico (le chart les aligne) |
| `NETWORK` | `NETWORK` de `lab.env`, sinon `192.168.56` | construit le CIDR host-only de l'autodétection d'adresse |
| `POD_CIDR` | `POD_CIDR` de `_out/cluster.env`, sinon `lab.env`, sinon `10.244.0.0/16` | CIDR de l'`IPPool` — doit rester égal au `podSubnet` de kubeadm |
| `HOSTONLY_CIDR` | `${NETWORK}.0/24` | à ne toucher que si ton host-only n'est pas un `/24` |

## 🔧 Ce que fait le script

1. **Garde-fous** : binaires, `/readyz`, refus si un autre CNI est déjà là, refus si kube-proxy
   est absent (`KUBE_PROXY_REPLACEMENT=true`), et refus si `POD_CIDR` diverge du `POD_CIDR`
   enregistré dans `_out/cluster.env`.
2. **[`namespace.yaml`](namespace.yaml)** — le namespace `tigera-operator`, créé **avant** le
   chart parce qu'il porte les labels PodSecurity `privileged`. Le `--create-namespace` de Helm
   ne pose aucun label. Sur kubeadm rien n'est appliqué au niveau cluster par défaut : c'est
   donc une assurance plutôt qu'une obligation — mais c'est elle qui garde l'opérateur
   fonctionnel sur un cluster durci (cf. ⚠️ Pièges).
3. **Chart `tigera-operator`** dans ce namespace. L'opérateur tourne en `hostNetwork` : il
   démarre **sans CNI**, c'est ce qui rend l'amorçage possible.
4. **Attente des CRD `operator.tigera.io`** : l'opérateur est lancé avec `-manage-crds=true`,
   c'est donc *lui* qui crée `installations` **et** `apiservers.operator.tigera.io`. Appliquer
   une CR avant ça échoue sur « no matches for kind … ».
5. **`kubectl apply` de [`installation.yaml`](installation.yaml)**, avec les deux CIDR
   substitués à la volée (même mécanique que `LAB_DOMAIN` dans `../platform-up.sh`), **puis de
   [`apiserver.yaml`](apiserver.yaml)** qui déploie le `calico-apiserver`.
6. **Attentes bornées** : DaemonSet `calico-system/calico-node` créé, `rollout status`
   (600 s, le temps du premier pull sur 8 VM), puis tous les nodes `Ready` (300 s).
   Chacune **échoue en erreur** avec la commande de diagnostic à lancer — aucun `|| true`.
7. **Résumé** + rappel en jaune des deux étapes manquantes pour les UI du lab.

### Les réglages Helm qui comptent

Le chart rend **quatre** custom resources (`Installation`, `APIServer`, `Goldmane`, `Whisker`)
et ne livre **aucun dossier `crds/`** — les CRD sont créées par l'opérateur à l'exécution
(`-manage-crds=true`). Les quatre doivent donc être coupées à l'installation, sinon Helm échoue
avant même de créer le namespace :

```
Error: unable to build kubernetes objects from release manifest: resource mapping not found
for name: "default" ... no matches for kind "APIServer" in version "operator.tigera.io/v1"
ensure CRDs are installed first
```

| `--set` | Pourquoi |
|---|---|
| `installation.enabled=false` | le chart sait générer la CR `Installation` lui-même ; on la sort dans [`installation.yaml`](installation.yaml) pour avoir **un** fichier relisible et **un seul** propriétaire de l'objet (pas Helm *et* `kubectl apply`) |
| `apiServer.enabled=false` | même raison, CR sortie dans [`apiserver.yaml`](apiserver.yaml) et appliquée une fois les CRD présentes. Le `calico-apiserver` **est** bien déployé : il expose `projectcalico.org/v3` → objets Calico au `kubectl`, pas besoin de `calicoctl` |
| `goldmane.enabled=false` + `whisker.enabled=false` | l'agrégateur de flux + l'UI livrés par Calico 3.32, coupés pour garder le lab léger (la RAM des VM est comptée, cf. `lab.env`). Les rallumer impose d'extraire leurs CR de la même façon — `--set goldmane.enabled=true` seul réintroduit l'échec d'amorçage ci-dessus |

### Les champs de `installation.yaml` qui comptent

| Champ | Valeur | Pourquoi |
|---|---|---|
| `calicoNetwork.nodeAddressAutodetectionV4.cidrs` | `["192.168.56.0/24"]` | **LE point clé** : force l'adresse host-only (cf. ⚠️ Pièges) |
| `ipPools[0].cidr` | `10.244.0.0/16` | identique au `podSubnet` de kubeadm |
| `ipPools[0].encapsulation` | `VXLAN` | encapsulation inconditionnelle ; `VXLANCrossSubnet` retomberait sur du routage direct entre nodes du même `/24`, ce qui suppose que le commutateur host-only relaie des paquets à IP source « de pod » — non vérifié. Même choix que flannel et Cilium |
| `calicoNetwork.bgp` | `Disabled` | pas de pair BGP sur un host-only ⇒ BIRD ne sert à rien (et donc pas d'annonce d'IP de service) |
| `calicoNetwork.linuxDataplane` | `Iptables` | on garde le kube-proxy posé par `kubeadm init` — d'où le `KUBE_PROXY_REPLACEMENT=false` obligatoire |
| `calicoNetwork.mtu` | `1450` | 1500 (host-only) − 50 (entêtes VXLAN IPv4) |
| `kubeletVolumePluginPath` | `None` | **allègement du lab** : coupe le driver CSI Calico (et son DaemonSet `csi-node-driver` par node). Il ne sert qu'aux volumes éphémères de flow logs, inutilisés ici |
| `flexVolumePath` | `None` | **allègement du lab** : sans ça l'opérateur ajoute un init-container `flexvol-driver` qui monte `/usr/libexec/kubernetes/kubelet-plugins/volume/exec/`. FlexVolume est déprécié depuis Kubernetes 1.23 et n'alimente ici que Dikastes (policy L7), inutilisé |

## ✅ Vérifier

```bash
kubectl -n tigera-operator get pods                       # tigera-operator Running
kubectl get tigerastatus                                  # calico / apiserver : AVAILABLE=True
kubectl -n calico-system get pods -o wide                 # un calico-node par node + typha
kubectl get nodes                                         # tous Ready
kubectl get installation default -o yaml                  # la CR telle que l'opérateur l'a complétée
kubectl get ippools.projectcalico.org default-ipv4-ippool -o yaml   # cidr + vxlanMode Always
```

**Le contrôle qui compte vraiment** : l'adresse retenue par chaque node doit être en
`192.168.56.x`, **jamais** `10.0.2.15`.

```bash
COLS='NODE:.metadata.name'
COLS="$COLS,ADDR:.metadata.annotations.projectcalico\.org/IPv4Address"
COLS="$COLS,VXLAN:.metadata.annotations.projectcalico\.org/IPv4VXLANTunnelAddr"
kubectl get nodes -o "custom-columns=$COLS"
```

Puis un test de trafic cross-node (c'est là que se voit le piège de la carte NAT) :

```bash
kubectl run t1 --image=busybox --restart=Never --command -- sleep 3600
kubectl run t2 --image=busybox --restart=Never --command -- sleep 3600
kubectl get pods -o wide                                  # vérifie qu'ils sont sur 2 nodes différents
kubectl exec t1 -- ping -c3 "$(kubectl get pod t2 -o jsonpath='{.status.podIP}')"
kubectl exec t1 -- nslookup kubernetes.default            # DNS = CoreDNS, souvent sur un autre node
kubectl delete pod t1 t2
```

## 🌐 Rendre les UI du lab joignables (MetalLB)

Calico ne fournit pas d'IP de `LoadBalancer` : **c'est à toi de poser un annonceur L2.**
Ce dossier ne l'installe pas. Deux choses à faire, dans cet ordre.

**1. Installer MetalLB en mode L2** sur la même plage que celle qu'utilise Cilium
(`192.168.56.200` → `192.168.56.230`, la **première IP** revenant à `main-gateway`) :

```bash
helm repo add metallb https://metallb.github.io/metallb
helm upgrade --install metallb metallb/metallb --version 0.16.1 \
  -n metallb-system --create-namespace
```

Puis un `IPAddressPool` + une `L2Advertisement` (`metallb.io/v1beta1`) couvrant la plage.

> ℹ️ **PodSecurity** : le `speaker` MetalLB tourne en `hostNetwork` avec `NET_RAW`. kubeadm
> n'applique rien au niveau cluster, il démarre donc tel quel — mais si tu durcis l'admission,
> étiquette le namespace `metallb-system` en `pod-security.kubernetes.io/enforce: privileged`,
> même recette que [`../observability/namespace.yaml`](../observability/namespace.yaml).

**2. Retirer la `loadBalancerClass` spécifique à Cilium.**
[`../envoy-gateway/Envoy-Proxy.yml`](../envoy-gateway/Envoy-Proxy.yml) épingle aujourd'hui,
**ligne 13** :

```yaml
        loadBalancerClass: io.cilium/l2-announcer
```

> ⚠️ **Tant que cette ligne est là, MetalLB ne servira pas le Service.** Une
> `loadBalancerClass` dit à Kubernetes « seul ce contrôleur a le droit de traiter ce
> Service » : MetalLB l'ignorera et l'IP restera `<pending>` même avec un pool valide.
> Il faut **supprimer** la ligne (n'importe quel annonceur prend alors la main) ou la
> remplacer par la classe de l'annonceur retenu.

Une fois les deux points faits :

```bash
kubectl -n envoy-gateway-system get svc                   # EXTERNAL-IP = 192.168.56.200
ping -c1 192.168.56.200                                   # depuis l'hôte : l'ARP doit répondre
```

## ⚠️ Pièges

- **Carte NAT élue pour les tunnels** — le piège maison, cf. `CLAUDE.md`. Chaque VM a
  `enp0s3` (NAT, `10.0.2.15`, **la même IP sur toutes les VMs**, et c'est elle qui porte la
  route par défaut) et `enp0s8` (host-only, `192.168.56.x`). L'autodétection par défaut de
  Calico (`firstFound`) suit la route par défaut ⇒ tous les nodes se déclarent en
  `10.0.2.15`, tous les VTEP VXLAN pointent vers un NAT isolé, et le trafic pod cross-node
  + le DNS sont cassés. D'où `nodeAddressAutodetectionV4.cidrs: ["192.168.56.0/24"]`. Même
  problème, même parade que `--iface-can-reach` (flannel) et `devices=<host-only>` (Cilium).
- **Un niveau PodSecurity `baseline` bloque l'opérateur, et ça échoue SILENCIEUSEMENT.**
  L'opérateur a besoin du `hostNetwork` (c'est ce qui lui permet de démarrer sans aucun CNI) et
  d'un hostPath `/var/lib/calico`. kubeadm n'applique **rien** au niveau cluster : ça ne mord
  donc pas d'origine — mais ça mord sur tout cluster au défaut durci. Le
  `helm --create-namespace` ne pose aucun label PSS : sans [`namespace.yaml`](namespace.yaml),
  le `Deployment` serait bien créé mais le ReplicaSet n'arriverait à créer aucun pod. Le piège, c'est
  le symptôme : `kubectl -n tigera-operator get pods` ne renvoie **rien du tout** — pas un pod
  en erreur, zéro pod — et le script meurt sur le timeout du `rollout status`. La cause n'est
  visible que dans les events du ReplicaSet : `kubectl -n tigera-operator describe rs`. Même
  recette que [`../observability/namespace.yaml`](../observability/namespace.yaml).
  > 💡 Si tu as déjà rencontré l'échec, corriger les labels ne suffit pas : le ReplicaSet est en
  > backoff exponentiel et peut rester inactif au-delà des 300 s de timeout. Relance-le avec
  > `kubectl -n tigera-operator rollout restart deploy/tigera-operator`, puis rejoue le script.
- **CIDR de l'`IPPool` ≠ `podSubnet` de kubeadm** = réseau pod silencieusement cassé.
  Le script refuse de continuer s'il détecte l'écart dans `_out/cluster.env`, mais si tu
  changes l'un, change l'autre.
- **Changer de CNI n'est PAS une bascule à chaud.** Passer de Cilium à Calico (ou l'inverse)
  sur un cluster vivant laisse des routes, des règles iptables/eBPF et des `/etc/cni/net.d`
  contradictoires. La procédure est : `./kubeadm/cluster-reset.sh` (ou `vagrant destroy`) →
  `CNI=calico` dans `lab.env` → `./kubeadm/cluster-up.sh` → `./_k8s/calico/calico-up.sh`. Le
  garde-fou du script est là pour t'empêcher de le faire par erreur, pas pour rendre
  l'opération possible.
- **Pas de `loadBalancerClass` Cilium** : cf. la section 🌐 ci-dessus. C'est la cause n°1
  d'un `EXTERNAL-IP <pending>` qui persiste *après* avoir installé MetalLB.
- **Dataplane eBPF : tentant, écarté.** Il exigerait `bpfNetworkBootstrap: Enabled`,
  `kubeProxyManagement: Enabled` et une `FelixConfiguration` (`cgroupV2Path`), et il prendrait
  la main sur kube-proxy — exactement ce que `KUBE_PROXY_REPLACEMENT=false` dit qu'on ne fait
  *pas* ici. Trop de pièces mobiles pour le CNI « de comparaison » du lab : si on veut de
  l'eBPF, on prend Cilium.
- **`kubectl delete -f installation.yaml` ne désinstalle pas proprement Calico** : l'opérateur
  supprime `calico-node` et tous les nodes retombent `NotReady` d'un coup, pods compris.
  Utilise `helm uninstall` (cf. 🧹) ou, mieux, détruis le lab.
- **MetalLB L2 : une seule node répond à l'ARP par IP.** Comme la
  `CiliumL2AnnouncementPolicy`, ce n'est pas de l'équilibrage : un speaker est élu par
  adresse, tout le trafic du VIP entre par ce node, puis kube-proxy répartit. Une bascule de
  speaker prend quelques secondes (le temps du ré-ARP) — normal, pas un incident.

## 🚑 Dépannage

| Symptôme | Cause probable | Quoi faire |
|---|---|---|
| Le script échoue sur « un autre CNI est déjà installé » | tu relances Calico sur le cluster Cilium (ou flannel) du lab | c'est le garde-fou : rebuild du cluster, pas de bascule à chaud |
| `helm` échoue sur `no matches for kind "APIServer"` / `ensure CRDs are installed first` | une CR du chart est activée alors que sa CRD n'existe pas encore | garder les quatre CR coupées (cf. le tableau des `--set`) ; les CR vivent dans `installation.yaml` / `apiserver.yaml` |
| `rollout status` en timeout et `get pods` montre **zéro** pod dans `tigera-operator` | PodSecurity `baseline` refuse l'opérateur (hostNetwork + hostPath) | `kubectl -n tigera-operator describe rs` pour confirmer, appliquer `namespace.yaml`, puis `rollout restart` |
| CRD `installations.operator.tigera.io` jamais créée | l'opérateur ne joint pas l'apiserver ou n'a pas démarré | `kubectl -n tigera-operator logs deploy/tigera-operator` |
| `calico-node` en `Init:` / `CreateContainerConfigError` | un hostPath en lecture seule (typiquement le `flexvol-driver` si `flexVolumePath` a été retiré) | vérifie `kubectl get installation default -o yaml` ⇒ `flexVolumePath: None` |
| Nodes `Ready` mais DNS KO depuis un pod | adresse NAT élue pour les tunnels | relis la 1re puce des ⚠️ Pièges, puis la commande d'annotations de ✅ Vérifier |
| `kubectl get tigerastatus` → `Degraded` | l'opérateur explique pourquoi dans le message | `kubectl get tigerastatus calico -o yaml` |
| Gateway en `EXTERNAL-IP <pending>` | **normal sans MetalLB** | section 🌐, les **deux** étapes |
| Pods `Pending` avec `no IP addresses available in range` | bloc `/26` épuisé sur ce node ou `IPPool` trop petit | `kubectl get ipamblocks.crd.projectcalico.org` |

## 🧹 Désinstaller

Le chart embarque un hook `pre-delete` (Job `tigera-operator-uninstall`) qui nettoie la CR
avant de retirer l'opérateur :

```bash
helm uninstall calico -n tigera-operator
```

> ⚠️ **Ça coupe le CNI** : tous les nodes repassent `NotReady` et le réseau pod disparaît.
> Ne le fais pas « pour voir » sur un lab qui héberge quelque chose. Pour revenir à Cilium,
> détruis et reconstruis le cluster (`./kubeadm/cluster-reset.sh` → `CNI=cilium` →
> `./kubeadm/cluster-up.sh` → `./_k8s/platform-up.sh`).

## 📚 Références

- [Calico — Installation API (`operator.tigera.io/v1`)](https://docs.tigera.io/calico/latest/reference/installation/api)
- [Calico — Configure BGP peering / advertise service IPs](https://docs.tigera.io/calico/latest/networking/configuring/bgp)
- [Calico — Get started with NetworkPolicy](https://docs.tigera.io/calico/latest/network-policy/get-started/calico-policy/calico-network-policy)
- [MetalLB — Layer 2 configuration](https://metallb.io/configuration/#layer-2-configuration)
- [`../cilium/LISEZ-MOI.md`](../cilium/LISEZ-MOI.md) — le CNI par défaut du lab, et son annonce L2
- [`../envoy-gateway/LISEZ-MOI.md`](../envoy-gateway/LISEZ-MOI.md) — le consommateur du VIP `.200`
