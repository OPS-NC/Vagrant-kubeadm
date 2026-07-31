<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🐝 `cilium/` — CNI, IP LoadBalancer et annonce L2 (ARP)

> **La brique réseau du lab.** Cilium fournit le CNI (sans lui les nodes restent `NotReady`)
> et joue en plus le rôle de « cloud provider » : il attribue aux Services `type: LoadBalancer`
> une **vraie IP du réseau host-only** `192.168.56.0/24` et l'annonce en **ARP**. C'est ce
> mécanisme qui produit le VIP `192.168.56.200` du point d'entrée Envoy — sans MetalLB.

## 🎯 À quoi ça sert

- **CNI** en mode tunnel **VXLAN**, épinglé sur l'interface host-only (cf. ⚠️ Pièges).
- **IP LoadBalancer** : un pool `.200-.230` remplace le cloud provider absent.
- **Annonce L2 (ARP)** : l'IP devient joignable depuis l'hôte, donc via Tailscale
  (cf. [`../LISEZ-MOI.md`](../LISEZ-MOI.md), section « Accès distant »).
- **Observabilité réseau** : Hubble (relay + UI) est activé, pratique pour montrer les flux.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| Cluster bootstrapé avec **`CNI=cilium`** (`./kubeadm/cluster-up.sh`, le défaut — `CNI=none` est équivalent ici) | `kubeadm init` n'installe aucun CNI : c'est Cilium qui prend la place | `kubectl get nodes` → `NotReady` **avant** l'install, c'est normal |
| `_out/cluster.env` présent | il porte les faits **détectés** que lit le script : `HOSTONLY_IF`, `POD_CIDR`, `VIP`, `KUBE_PROXY_REPLACEMENT` | `cat _out/cluster.env` |
| Une interface host-only (en général **`enp0s8`**) | source de l'annonce ARP **et** des tunnels VXLAN | `vagrant ssh k8s-cp1 -c 'ip -br a'` |
| `kubectl` + `helm`, `KUBECONFIG` posé | le script vérifie les binaires puis `/readyz` | `helm version` |

## ⚡ Installation

```bash
./_k8s/cilium/cilium-up.sh
```

Chart `cilium/cilium` **`1.20.0`**, lu dans `lab.env` (`CILIUM_VERSION`) et surchargeable au coup
par coup (`CILIUM_VERSION=1.20.1 ./_k8s/cilium/cilium-up.sh`). Idempotent (`helm upgrade --install` +
`kubectl apply`). `../platform-up.sh` l'appelle en étape **[1/4]** — tu n'as donc rien à lancer
ici si tu déroules la plateforme complète.

> ⚠️ **Ne prends pas le §9 du README racine comme référence d'installation.** Il montre le
> `helm upgrade` « à la main » pour expliquer qui installe le CNI, mais **sans `--version`**
> (tu prends la dernière release publiée, pas celle validée ici) et **sans appliquer
> `cilium-l2.yml`** — donc sans pool d'IP : la Gateway resterait en `EXTERNAL-IP <pending>`.
> La source de vérité, c'est `cilium-up.sh`.

## 🔧 Ce que fait le script

1. **Lit `_out/cluster.env`** (puis `lab.env` en repli) : `HOSTONLY_IF`, `POD_CIDR`, `VIP`,
   `KUBE_PROXY_REPLACEMENT` — des faits détectés, pas devinés ;
2. **installe Cilium en Helm** dans `kube-system` avec les valeurs ci-dessous ;
3. **attend** `condition=Ready` sur tous les nodes (300 s max) — c'est le CNI qui les débloque ;
4. **applique `cilium-l2.yml`** : pool d'IP LoadBalancer + politique d'annonce ARP, avec la plage
   et le nom de l'interface substitués.

### Les `--set` qui comptent

| Réglage | Pourquoi |
|---|---|
| `devices=<HOSTONLY_IF>` | **le point clé** : épingle la carte **host-only** (lue dans `_out/cluster.env`, jamais codée en dur). Sans ça, Cilium prend la carte de la route par défaut (NAT `10.0.2.15`, identique sur chaque VM) → VTEP et ARP inutilisables |
| `routingMode=tunnel` + `tunnelProtocol=vxlan` | encapsulation entre nodes. Il n'y a **aucun routeur** sur le réseau host-only : le routage natif exigerait une route statique par node côté VirtualBox, le tunnel supprime le problème |
| `ipam.mode=cluster-pool` + `ipam.operator.clusterPoolIPv4PodCIDRList={<POD_CIDR>}` + `clusterPoolIPv4MaskSize=24` | ⚠️ **le piège** : le défaut de cluster-pool est `10.0.0.0/8`, sans aucun rapport avec le `podSubnet` déclaré à kubeadm. Si on ne repasse pas `POD_CIDR` explicitement, kubeadm et Cilium ne parlent pas du même réseau |
| `kubeProxyReplacement=<KUBE_PROXY_REPLACEMENT>` | `true` (défaut) : `kubeadm init` a tourné avec `--skip-phases=addon/kube-proxy`, il n'y a **aucun kube-proxy** et Cilium sert les Services en eBPF. `false` : kube-proxy est là, Cilium se pose par-dessus |
| `k8sServiceHost=<VIP>` + `k8sServicePort=6443` | **obligatoire sans kube-proxy** : plus rien ne provisionne la ClusterIP de l'apiserver, l'agent ne peut donc pas s'amorcer via `kubernetes.default`. On vise la **VIP keepalived**, pas l'IP propre de cp1 : la VIP survit à la perte de cp1, et c'est l'adresse déjà figée dans les certificats |
| `l2announcements.enabled=true` | **active** le contrôleur qui répond à l'ARP ; sans lui la `CiliumL2AnnouncementPolicy` est ignorée |
| `externalIPs.enabled=true` | prise en charge des `externalIPs` de Services |
| `envoy.enabled=false` | pas besoin de l'Envoy **embarqué** de Cilium : le lab utilise le contrôleur [`../envoy-gateway/`](../envoy-gateway/LISEZ-MOI.md), un composant distinct |
| `hubble.*` + `bandwidthManager.enabled=true` | observabilité des flux + gestion de bande passante (démos) |

> ⚠️ **Ce qui est volontairement *absent*.** La page « Talos » de la doc Cilium recommande
> `cgroup.autoMount.enabled=false`, `cgroup.hostRoot=/sys/fs/cgroup` et des listes explicites de
> `securityContext.capabilities.*`. Ce sont des contournements **Talos**, activement nuisibles sur
> Debian : le chart monte lui-même le cgroup2 et calcule les capabilities dont l'agent a besoin.
> Ne les remets pas.

### `cilium-l2.yml` — deux objets

| Objet | Rôle |
|---|---|
| `CiliumLoadBalancerIPPool` **`lb-pool-56`** | réserve la plage **`.200` → `.230`** ; chaque Service `LoadBalancer` pioche dedans |
| `CiliumL2AnnouncementPolicy` **`l2-lb-workers`** | **annonce en ARP** ces IP sur la carte host-only, **depuis les workers uniquement** (les control planes sont exclus par le `nodeSelector`) |

Pourquoi ces choix :

- **Plage `.200-.230`** : hors des IP de nodes (CP `.10/.20/.30`, workers `.101+`), de la VIP
  d'API `.5` et de la passerelle `.1`. À garder alignée si tu changes le plan d'adressage de
  `lab.env`.
- **Interface host-only** : la seule carte par laquelle l'hôte peut joindre les VMs. Le manifeste
  porte `^enp0s8$` comme défaut ; `cilium-up.sh` le réécrit depuis `HOSTONLY_IF` de
  `_out/cluster.env`, donc une box qui la nomme `eth1` marche sans rien éditer.
- **Workers seulement** : évite qu'un control plane réponde à l'ARP du VIP. Sur une topologie
  single node (aucun worker), il faut retirer le `nodeSelector`, sinon plus personne n'annonce.

## ✅ Vérifier

```bash
kubectl -n kube-system get pods -l k8s-app=cilium              # un agent par node, Running
kubectl get nodes                                              # tous Ready
kubectl get ciliumloadbalancerippool                           # lb-pool-56, DISABLED=false, IPS AVAILABLE
kubectl get ciliuml2announcementpolicy                         # l2-lb-workers
kubectl -n envoy-gateway-system get svc                        # EXTERNAL-IP = 192.168.56.200
ping -c1 192.168.56.200                                        # depuis l'hôte : l'ARP doit répondre

# Diagnostic côté agent. ⚠️ le binaire dans le pod a été RENOMMÉ `cilium` -> `cilium-dbg`
# en v1.15 : `... -- cilium status` n'existe plus.
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list   # vide => aucun Service eBPF
```

Avec `KUBE_PROXY_REPLACEMENT=true` il n'y a **aucun DaemonSet `kube-proxy`** dans `kube-system`,
et c'est l'état attendu — `cilium-dbg status` doit afficher `KubeProxyReplacement: True`.

## 🌐 Hubble UI (non exposée)

Hubble est activé mais **aucune `HTTPRoute` ne l'expose** : c'est volontaire (l'UI n'a pas
d'authentification). Accès ponctuel par port-forward :

```bash
kubectl -n kube-system port-forward svc/hubble-ui 12000:80     # puis http://localhost:12000
```

## ⚠️ Pièges

- **Service coincé en `EXTERNAL-IP: <pending>`** → pool absent (`cilium-l2.yml` non appliqué),
  plage épuisée, ou `l2announcements` non activé à l'install (cas typique quand on a suivi le
  §9 du README racine au lieu de `cilium-up.sh`).
- **VIP qui répond au `ping` depuis l'hôte mais pas depuis un peer Tailscale** → normal :
  l'ARP ne traverse pas un routeur. Il faut `--advertise-routes` sur l'hôte
  (cf. [`../LISEZ-MOI.md`](../LISEZ-MOI.md)).
- **`--set autoDirectNodeRoutes=true` (ou `ipv4NativeRoutingCIDR`) est interdit ici** : ce sont
  des options de **routage natif**, incompatibles avec le mode tunnel. L'agent sort en `fatal`
  (« auto-direct-node-routes cannot be used with tunneling ») et boucle en `CrashLoopBackOff`.
- **Le remplacement de kube-proxy se décide au bootstrap, pas ici.** `KUBE_PROXY_REPLACEMENT=true`
  fait lancer à `kubeadm/cluster-up.sh` un `kubeadm init --skip-phases=addon/kube-proxy` ; ce
  script relit ensuite la même valeur dans `_out/cluster.env`. N'en changer qu'un des deux fait
  perdre TOUS les Services du cluster. Changer d'avis = reconstruire :
  `./kubeadm/cluster-reset.sh` puis `./kubeadm/cluster-up.sh`.
- **`k8sServiceHost` n'est pas optionnel sans kube-proxy.** Plus rien ne provisionne la ClusterIP
  `10.96.0.1` de l'apiserver : un agent qui ne connaît que `kubernetes.default` ne se connecte
  jamais et boucle en `CrashLoopBackOff` sur `Unable to contact k8s api-server`.
- **CIDR pod divergent.** `ipam.mode=cluster-pool` part par défaut sur `10.0.0.0/8`, quoi qu'on
  ait déclaré à kubeadm. Symptôme : les pods prennent des adresses `10.0.x.x` alors que
  `kubectl get node -o jsonpath='{.spec.podCIDR}'` annonce `10.244.x.0/24`. Il faut toujours
  repasser `POD_CIDR` (le script le fait).
- **Ne relance pas le script pour « rafraîchir » un cluster en production de démo** sans lire
  le diff Helm : un changement de `routingMode` ou de `devices` coupe le trafic le temps du
  redéploiement des agents.
- **Les deux objets ne partagent PAS la même apiVersion**, et cette asymétrie est voulue —
  vérifiée sur la documentation Cilium 1.20.0 :
  `CiliumLoadBalancerIPPool` est en `cilium.io/v2`, tandis que `CiliumL2AnnouncementPolicy` est
  toujours en `cilium.io/v2alpha1`. Les aligner « par cohérence » est justement l'erreur à ne
  pas faire : le pool cesse silencieusement d'être servi en `v2alpha1`, et le Gateway repasse
  en `<pending>`.
  Si une future version de Cilium promeut la policy en `v2`, le symptôme est un rejet
  d'`apiVersion` au `kubectl apply` — à vérifier avec
  `kubectl get crd ciliuml2announcementpolicies.cilium.io -o jsonpath='{.spec.versions[*].name}'`.

## 📚 Références

- [Cilium — kube-proxy replacement](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
- [Cilium — IPAM cluster-pool](https://docs.cilium.io/en/stable/network/concepts/ipam/cluster-pool/)
- [Cilium — LoadBalancer IPAM](https://docs.cilium.io/en/stable/network/lb-ipam/)
- [Cilium — L2 Announcements](https://docs.cilium.io/en/stable/network/l2-announcements/)
- [`../envoy-gateway/LISEZ-MOI.md`](../envoy-gateway/LISEZ-MOI.md) — le consommateur du VIP `.200`
