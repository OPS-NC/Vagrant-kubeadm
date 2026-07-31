#!/usr/bin/env bash
#
# provision.sh — préparation système d'un node, exécutée DANS la VM par Vagrant
# (cf. `node.vm.provision "shell"` du Vagrantfile). Ne bootstrape AUCUN cluster :
# à la fin de `vagrant up`, chaque VM est prête à recevoir un `kubeadm init/join`,
# et rien de plus. Le bootstrap est piloté depuis l'hôte par kubeadm/cluster-up.sh.
#
# Ce que ce script pose, dans l'ordre (chaque étape suppose la précédente) :
#   1. /etc/hosts        résolution déterministe de tous les nodes du lab
#   2. mise à jour       apt upgrade non interactif, GRUB préconfiguré (cf. étape 2)
#   3. prérequis noyau   swap coupé, modules, sysctl
#   4. paquets de base   dont open-iscsi/nfs-common (Longhorn) et conntrack (kube-proxy)
#   5. containerd        2.x (dépôt Docker) ou 1.7 (Debian), cgroup systemd
#   6. kubeadm/kubelet/kubectl  version épinglée puis `apt-mark hold`
#   7. images            pré-tirées, pour que `kubeadm init` ne télécharge plus rien
#   8. keepalived        VIP de l'API en VRRP — control planes uniquement
#
# Idempotent : relançable à volonté (`vagrant provision`).
#
# ⚠️ `vagrant provision` N'EST PAS un chemin de montée de version Kubernetes : l'étape 6
#    réinstalle K8S_VERSION sur TOUS les nodes d'un coup, sans jamais appeler
#    `kubeadm upgrade`. Bumper lab.env puis reprovisionner mettrait chaque kubelet une
#    mineure devant l'apiserver. Cf. kubeadm/UPGRADE.md.
#
# Variables reçues du Vagrantfile : NODE_NAME NODE_ROLE NODE_INDEX NODE_IP NETWORK
# VIP CP_IPS CP_IP_START CP_IP_STEP VRRP_ROUTER_ID K8S_VERSION K8S_APT_MINOR CONTAINERD_SOURCE
# REGISTRY_MIRROR HOSTS_ENTRIES SYSTEM_UPGRADE KUBE_PROXY_REPLACEMENT
set -euo pipefail

# --- Non-interactivité : ceinture ET bretelles ------------------------------
# Un provisionneur Vagrant n'a PAS de terminal. La moindre question debconf ne
# s'affiche donc nulle part : elle bloque `vagrant up` jusqu'au timeout, sans le
# moindre indice de ce qui est attendu. Les trois réglages ne font pas doublon :
#   DEBIAN_FRONTEND=noninteractive  debconf ne pose plus de question et prend le défaut
#   DEBIAN_PRIORITY=critical        même les questions « haute priorité » sont sautées
#   NEEDRESTART_MODE=a              needrestart redémarre les services sans demander
#                                   (il est tiré par plusieurs paquets sur Debian 13 et
#                                   sa liste de services à redémarrer est un prompt)
export DEBIAN_FRONTEND=noninteractive
export DEBIAN_PRIORITY=critical
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

NODE_NAME="${NODE_NAME:-$(hostname)}"
NODE_ROLE="${NODE_ROLE:-worker}"
NODE_INDEX="${NODE_INDEX:-1}"
NODE_IP="${NODE_IP:?NODE_IP manquant (fourni par le Vagrantfile)}"
NETWORK="${NETWORK:-192.168.56}"
VIP="${VIP:-${NETWORK}.5}"
CP_IPS="${CP_IPS:-}"
CP_IP_START="${CP_IP_START:-10}"
CP_IP_STEP="${CP_IP_STEP:-10}"
VRRP_ROUTER_ID="${VRRP_ROUTER_ID:-51}"
K8S_VERSION="${K8S_VERSION:-1.36.3}"
K8S_APT_MINOR="${K8S_APT_MINOR:-v1.36}"
CONTAINERD_SOURCE="${CONTAINERD_SOURCE:-docker}"
REGISTRY_MIRROR="${REGISTRY_MIRROR:-}"
HOSTS_ENTRIES="${HOSTS_ENTRIES:-}"
SYSTEM_UPGRADE="${SYSTEM_UPGRADE:-true}"
KUBE_PROXY_REPLACEMENT="${KUBE_PROXY_REPLACEMENT:-true}"

# Normalisation + REJET de l'inconnu, comme SELF_SIGNED et UNTAINT_CP ailleurs dans le
# dépôt. Sans ce `case`, `SYSTEM_UPGRADE=True` ou `yes` sauterait SILENCIEUSEMENT la
# mise à jour — et une faute de frappe (`flase`) ferait la même chose, sans un mot.
for v in SYSTEM_UPGRADE KUBE_PROXY_REPLACEMENT; do
  eval "val=\${$v}"
  val="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
  case "$val" in
    true|false) eval "$v=\$val" ;;
    *) echo "ERREUR : ${v}='${val}' inconnu (true|false)." >&2 ; exit 1 ;;
  esac
done

log() { printf '\n\033[1;36m[%s] ==> %s\033[0m\n' "$NODE_NAME" "$*"; }

# ============================================================================
log "[1/8] Résolution des noms (/etc/hosts)"
# Bloc délimité et réécrit à chaque passage : relancer `vagrant provision` ne doit
# pas empiler dix fois les mêmes lignes.
if [ -n "$HOSTS_ENTRIES" ]; then
  sed -i '/# >>> vagrant-kubeadm/,/# <<< vagrant-kubeadm/d' /etc/hosts
  {
    echo "# >>> vagrant-kubeadm"
    echo "$HOSTS_ENTRIES"
    echo "${VIP}  kubernetes-api ${NODE_NAME%%-*}-api"
    echo "# <<< vagrant-kubeadm"
  } >>/etc/hosts
fi
# Debian mappe le hostname sur 127.0.1.1. kubelet résout son propre nom pour
# s'enregistrer : laissé en place, le node s'annonce en loopback et devient
# injoignable depuis les autres nodes.
sed -i "/^127\.0\.1\.1\s\+${NODE_NAME}\b/d" /etc/hosts

# ============================================================================
if [ "$SYSTEM_UPGRADE" = "true" ]; then
log "[2/8] Mise à jour du système (non interactive, GRUB préconfiguré)"

# --- LE PIÈGE : grub-pc et sa question debconf --------------------------------
# `apt-get upgrade` sur une box Debian met tôt ou tard `grub-pc` à jour. Son postinst
# pose alors une question debconf `grub-pc/install_devices` — « sur quel(s) disque(s)
# installer GRUB ? » — parce que la réponse n'est pas déductible : GRUB doit être écrit
# dans le MBR d'un disque physique, et le paquet ne peut pas le deviner.
#
# Dans un provisionneur Vagrant il n'y a AUCUN terminal : la question ne s'affiche nulle
# part et `vagrant up` reste bloqué jusqu'au timeout. Pire, si elle est sautée sans
# réponse, GRUB n'est pas réécrit dans le MBR et la VM peut ne plus démarrer au reboot
# suivant — panne qui se manifeste bien après le provisioning, donc très loin de sa cause.
#
# On préconfigure donc la réponse AVANT toute mise à jour. C'est `debconf-set-selections`
# qui pose la réponse dans la base debconf ; le postinst la lira au lieu de demander.

# Le disque n'est pas codé en dur : on remonte du système de fichiers racine vers le
# disque parent. `/dev/sda` est le cas VirtualBox habituel, mais ce n'est qu'un repli —
# un provider différent (libvirt -> /dev/vda) ou un ordre de contrôleurs inattendu
# donnerait un autre nom, et une valeur fausse ici est exactement ce qu'on veut éviter.
root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
boot_disk=""
if [ -n "$root_src" ]; then
  parent="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
  [ -n "$parent" ] && boot_disk="/dev/${parent}"
fi
boot_disk="${boot_disk:-/dev/sda}"

if [ -d /sys/firmware/efi ]; then
  # En UEFI c'est `grub-efi` qui est installé : il écrit dans la partition ESP et ne
  # pose jamais `install_devices`. On préconfigure quand même — sans effet ici, mais
  # correct si la box bascule un jour en BIOS.
  echo "    démarrage UEFI détecté (grub-efi) — pas de question install_devices"
else
  echo "    démarrage BIOS — GRUB sera installé sur ${boot_disk}"
fi

debconf-set-selections <<EOF
grub-pc grub-pc/install_devices multiselect ${boot_disk}
grub-pc grub-pc/install_devices_disks_changed multiselect ${boot_disk}
grub-pc grub-pc/install_devices_empty boolean false
grub-pc grub-pc/postrm_purge_boot_grub boolean false
EOF

apt-get update -qq

# `upgrade` et surtout PAS `full-upgrade`/`dist-upgrade` : `upgrade` ne peut pas
# installer un paquet au nom nouveau, donc il laisse volontairement de côté les
# montées de noyau (linux-image-6.12.x est un NOUVEAU nom de paquet). C'est exactement
# ce qu'on veut : on met le système à jour sans changer le noyau sous les pieds des
# modules chargés à l'étape suivante (br_netfilter, iscsi_tcp), et sans imposer un reboot.
#
# --force-confdef + --force-confold : garder les fichiers de configuration en place
# sans poser la question « garder la version installée ou celle du mainteneur ? ».
apt-get -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  upgrade

apt-get -y -qq autoremove
else
log "[2/8] Mise à jour du système — ignorée (SYSTEM_UPGRADE=${SYSTEM_UPGRADE})"
apt-get update -qq
fi

# ============================================================================
log "[3/8] Prérequis noyau (swap, modules, sysctl)"

# --- swap ---
# NodeSwap est GA depuis 1.34, mais `failSwapOn` vaut TOUJOURS true par défaut :
# le kubelet refuse de démarrer avec du swap actif tant qu'on ne le configure pas
# explicitement. Sur un lab, on coupe — c'est le chemin le plus court et le mieux testé.
swapoff -a
sed -ri 's/^\s*([^#].*\s+swap\s+)/#\1/' /etc/fstab
# Debian 13 peut fournir le swap par une unité systemd (zram, swapfile) que
# /etc/fstab ne décrit pas : la masquer évite qu'il revienne au reboot.
# `|| true` sur TOUT le pipeline : sans unité de swap, systemctl sort en 1 et,
# sous `set -e` + `pipefail`, tuerait la préparation du node dès l'étape 2.
{ systemctl list-unit-files --type=swap --no-legend 2>/dev/null || true; } \
  | awk '{print $1}' | while read -r unit; do
      [ -n "$unit" ] && systemctl mask "$unit" >/dev/null 2>&1 || true
    done

# --- modules ---
# `overlay` est de toute façon chargé par le snapshotter de containerd, et Cilium en
# mode eBPF n'a pas besoin de `br_netfilter`. On les charge quand même : ils sont
# indispensables dès qu'on bascule sur calico/flannel (datapath iptables), et le lab
# doit rester utilisable avec les quatre valeurs de CNI.
tee /etc/modules-load.d/k8s.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay    || true
modprobe br_netfilter || true
# iSCSI : requis par Longhorn (_k8s/longhorn/). Sans lui les pods CSI tournent en boucle.
tee /etc/modules-load.d/iscsi.conf >/dev/null <<'EOF'
iscsi_tcp
EOF
modprobe iscsi_tcp || true

# --- sysctl ---
# La doc amont ne réclame plus que `ip_forward` et délègue le reste au CNI. Les
# `bridge-nf-call-*` restent nécessaires aux datapaths iptables (calico/flannel).
# `rp_filter=0` : le filtrage de chemin inverse casse le trafic pod chez plusieurs CNI.
tee /etc/sysctl.d/99-kubernetes.conf >/dev/null <<'EOF'
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.conf.all.rp_filter         = 0
net.ipv4.conf.default.rp_filter     = 0
EOF
sysctl --system >/dev/null

# ============================================================================
log "[4/8] Paquets de base"
# Pas de `apt-get update` ici : l'étape 2 vient de le faire, dans les deux branches
# (avec ou sans mise à jour du système). Le refaire ne coûterait que du temps de boot.
# conntrack + socat + ethtool : exigés par le preflight kubeadm et par kube-proxy.
# open-iscsi + nfs-common : prérequis Longhorn (_k8s/longhorn/).
# Sur Talos ces deux-là passaient par une extension système cuite dans l'image ;
# sur Debian c'est un simple paquet — c'est toute la différence de modèle.
apt-get install -y -qq \
  apt-transport-https ca-certificates curl gnupg gpg \
  conntrack socat ethtool iptables jq \
  open-iscsi nfs-common
install -m 0755 -d /etc/apt/keyrings

# keepalived UNIQUEMENT sur les control planes : le paquet Debian active son unité à
# l'installation, et sur un worker — qui n'aura jamais de keepalived.conf — elle
# échouerait en boucle, polluant les journaux pour rien.
if [ "$NODE_ROLE" = "controlplane" ]; then
  apt-get install -y -qq keepalived
fi

# iscsid doit tourner ET démarrer au boot pour Longhorn.
systemctl enable --now iscsid >/dev/null 2>&1 || true

# ============================================================================
log "[5/8] containerd (source : ${CONTAINERD_SOURCE})"
case "$CONTAINERD_SOURCE" in
  docker)
    # containerd 2.x. Seule la branche 2.x implémente la méthode CRI `RuntimeConfig`
    # dont kubeadm se sert pour lire le cgroup driver du runtime. En 1.36 son absence
    # n'est qu'un avertissement de preflight, mais le repli disparaît en 1.37 : la
    # branche 1.7 de Debian est une impasse (containerd#11346 fermé sans merge).
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
      curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
    fi
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      >/etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq containerd.io
    ;;
  debian)
    apt-get install -y -qq containerd containernetworking-plugins
    ;;
  *)
    echo "ERREUR : CONTAINERD_SOURCE='${CONTAINERD_SOURCE}' inconnu (docker|debian)." >&2
    exit 1
    ;;
esac

# ============================================================================
log "[6/8] kubelet / kubeadm / kubectl ${K8S_VERSION} (dépôt ${K8S_APT_MINOR})"
# kubernetes.io ne publie que la forme `.list` classique (pas de deb822) : c'est
# celle qui est testée en amont, on ne s'en écarte pas.
if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_APT_MINOR}/deb/Release.key" \
    | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/${K8S_APT_MINOR}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update -qq

# Le suffixe de révision Debian n'est pas toujours `-1.1` (1.36.2 a été republié en
# `-2.1`) : on demande donc `<version>-*` plutôt qu'un suffixe deviné. Le `hold` est
# levé le temps de l'installation, sans quoi une réinstallation serait ignorée.
apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
apt-get install -y -qq --allow-change-held-packages \
  "kubelet=${K8S_VERSION}-*" "kubeadm=${K8S_VERSION}-*" "kubectl=${K8S_VERSION}-*"
# `hold` : une montée de version doit être un geste DÉLIBÉRÉ (cf. kubeadm/UPGRADE.md),
# jamais l'effet de bord d'un `apt upgrade` qui casserait le skew kubelet/apiserver.
apt-mark hold kubelet kubeadm kubectl >/dev/null
systemctl enable kubelet >/dev/null 2>&1 || true

# --- Configuration containerd, maintenant que kubeadm peut nous dire quelle pause ---
# On INTERROGE kubeadm au lieu de coder la version en dur : le tag de `pause` change à
# chaque mineure, et un décalage entre celui de containerd et celui qu'attend kubeadm
# fait pré-tirer une image pour en utiliser une autre (invisible en ligne, fatal hors-ligne).
PAUSE_IMAGE="$(kubeadm config images list --kubernetes-version "v${K8S_VERSION}" 2>/dev/null \
                | grep -m1 '/pause:' || true)"
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.10.2}"

mkdir -p /etc/containerd
# Config régénérée à chaque passage : la version du fichier (v2 chez containerd 1.7,
# v3 chez 2.x) doit suivre le binaire réellement installé, pas un ancien fichier.
containerd config default >/etc/containerd/config.toml

# `SystemdCgroup` : Debian 13 est en cgroup v2 avec systemd comme gestionnaire. Si
# containerd reste sur `cgroupfs`, deux gestionnaires se disputent la même hiérarchie
# et les nodes deviennent instables sous charge. Le nom de la clé est identique en v2
# et en v3, un seul `sed` couvre les deux.
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Image `pause`. La clé a changé de nom ET d'emplacement entre les deux formats :
#   v2 (containerd 1.7) : sandbox_image = "..."  sous [plugins."io.containerd.grpc.v1.cri"]
#   v3 (containerd 2.x) : sandbox = '...'        sous [plugins.'io.containerd.cri.v1.images'.pinned_images]
# C'est LE piège de la migration 1.7 -> 2.x : une config recopiée telle quelle perd
# silencieusement le réglage.
if grep -q '^[[:space:]]*sandbox_image[[:space:]]*=' /etc/containerd/config.toml; then
  sed -i "s#^\([[:space:]]*sandbox_image[[:space:]]*=[[:space:]]*\).*#\1\"${PAUSE_IMAGE}\"#" \
    /etc/containerd/config.toml
fi
if grep -q "^[[:space:]]*sandbox[[:space:]]*=" /etc/containerd/config.toml; then
  sed -i "s#^\([[:space:]]*sandbox[[:space:]]*=[[:space:]]*\).*#\1'${PAUSE_IMAGE}'#" \
    /etc/containerd/config.toml
fi

# Miroir de registry (proxy pull-through). `config_path` est le seul réglage vide par
# défaut dans la config générée, en v2 comme en v3 : on le remplit sans dépendre du
# nom du plugin, qui a été renommé entre les deux formats.
if [ -n "$REGISTRY_MIRROR" ]; then
  sed -i "s#^\([[:space:]]*config_path[[:space:]]*=[[:space:]]*\)\(\"\"\|''\)#\1\"/etc/containerd/certs.d\"#" \
    /etc/containerd/config.toml
  mkdir -p /etc/containerd/certs.d/docker.io
  # `override_path` : le miroir est exposé sous un sous-chemin, qu'il faut traiter
  # comme la base de l'API du registry (sinon containerd y recolle un /v2 en double).
  tee /etc/containerd/certs.d/docker.io/hosts.toml >/dev/null <<EOF
server = "https://registry-1.docker.io"

[host."${REGISTRY_MIRROR}"]
  capabilities = ["pull", "resolve"]
  override_path = true
EOF
fi

systemctl daemon-reload
systemctl enable containerd >/dev/null 2>&1 || true
systemctl restart containerd

# crictl parle au même socket que le kubelet. Sans ce fichier, `crictl` part chercher
# dockershim et affiche des erreurs déroutantes lors des diagnostics.
tee /etc/crictl.yaml >/dev/null <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

# ============================================================================
log "[7/8] Pré-tirage des images"
# Fait ici, PENDANT `vagrant up`, donc en parallèle sur toutes les VM. `kubeadm init`
# n'a alors plus rien à télécharger, ce qui retire la plus grosse source de timeouts
# du bootstrap (et rend le lab reconstructible hors-ligne).
if [ "$NODE_ROLE" = "controlplane" ]; then
  kubeadm config images pull --kubernetes-version "v${K8S_VERSION}" >/dev/null 2>&1 \
    || echo "    (pré-tirage partiel — kubeadm init retéléchargera au besoin)"
else
  # Un worker n'héberge ni apiserver, ni etcd, ni scheduler : tirer les 7 images
  # gâcherait ~500 Mio par worker. `pause` lui sert toujours ; `kube-proxy` seulement
  # s'il est réellement installé — avec KUBE_PROXY_REPLACEMENT=true (le défaut du
  # dépôt) cluster-up.sh saute `addon/kube-proxy` et l'image ne servirait JAMAIS.
  images="$PAUSE_IMAGE"
  [ "$KUBE_PROXY_REPLACEMENT" != "true" ] && images="$images registry.k8s.io/kube-proxy:v${K8S_VERSION}"
  for img in $images; do
    crictl pull "$img" >/dev/null 2>&1 || true
  done
fi

# ============================================================================
# Détection de l'interface host-only. JAMAIS de nom codé en dur : Debian 13 utilise
# les noms prédictibles (`enp0s8`), mais certaines box exposent encore `eth1`. On
# cherche l'interface qui PORTE l'IP du node — infaillible et indépendant du nommage.
HOSTONLY_IF="$(ip -o -4 addr show 2>/dev/null \
                | awk -v pfx="${NODE_IP}/" '$4 ~ ("^" pfx) {print $2; exit}')"
if [ -z "$HOSTONLY_IF" ]; then
  HOSTONLY_IF="$(ip -o -4 route show 2>/dev/null \
                  | awk -v n="${NETWORK}.0/24" '$1 == n {print $3; exit}')"
fi
HOSTONLY_IF="${HOSTONLY_IF:-eth1}"

# Fiches de faits du node, relues par cluster-up.sh (via `vagrant ssh`) et par les
# scripts _k8s/ qui ont besoin du nom d'interface (annonce L2 de Cilium).
mkdir -p /etc/kubeadm-lab
tee /etc/kubeadm-lab/node.env >/dev/null <<EOF
NODE_NAME=${NODE_NAME}
NODE_ROLE=${NODE_ROLE}
NODE_INDEX=${NODE_INDEX}
NODE_IP=${NODE_IP}
HOSTONLY_IF=${HOSTONLY_IF}
VIP=${VIP}
K8S_VERSION=${K8S_VERSION}
EOF

# ============================================================================
if [ "$NODE_ROLE" = "controlplane" ]; then
log "[8/8] keepalived — VIP ${VIP} sur ${HOSTONLY_IF} (VRRP)"

# POURQUOI keepalived plutôt que kube-vip.
#   La VIP doit exister AVANT `kubeadm init`, puisque `controlPlaneEndpoint` pointe
#   dessus. kube-vip tourne en pod statique et fait son élection de leader via
#   l'API Kubernetes — c'est-à-dire à travers la VIP qu'il est censé porter : un
#   œuf-et-poule qu'on ne résout qu'avec la bidouille `super-admin.conf`, elle-même
#   fragile depuis que k8s 1.29 a déplacé `admin.conf` hors de `system:masters`.
#   keepalived, lui, est un démon VRRP : il ne connaît pas Kubernetes, pose la VIP
#   dès le boot de la VM, et le bootstrap n'a plus aucune dépendance circulaire.
#   kube-vip reste une alternative valable une fois le cluster en route (cf. README).

# VRRP en UNICAST et non en multicast : sur le switch virtuel host-only de VirtualBox,
# le multicast est le premier truc à se comporter bizarrement.
#
# ⚠️ LES PAIRS SONT LES CONTROL PLANES *POSSIBLES*, PAS CEUX QUI EXISTENT AUJOURD'HUI.
#    C'est ce qui rend la croissance 1 CP -> 3 CP sûre, et ce n'est pas un détail.
#
#    Le piège, si on n'y prend pas garde : avec CONTROL_PLANES=1, la liste des pairs
#    serait VIDE et le bloc `unicast_peer` absent. Or keepalived, face à un
#    `unicast_src_ip` sans aucun pair, ne refuse PAS la configuration : il émet un
#    CONFIG_DEPRECATED et RETOMBE SILENCIEUSEMENT EN MULTICAST.
#    Passer ensuite à CONTROL_PLANES=3 ne re-provisionne PAS cp1 (Vagrant ne rejoue les
#    provisionneurs que sur les VM neuves, sauf `--provision`) : cp1 reste donc en
#    multicast pendant que cp2/cp3 démarrent en unicast réel. Et les deux modes sont
#    MUTUELLEMENT SOURDS — un socket bindé sur l'adresse multicast ne reçoit pas
#    l'unicast, et réciproquement. cp1 se croit seul et prend la VIP ; cp2 se croit
#    seul aussi et la prend également. DEUX nodes portent alors 192.168.56.5 :
#    course ARP, API intermittente, et comme admin.conf, kubelet.conf ET le
#    k8sServiceHost de Cilium pointent tous sur la VIP, c'est tout le cluster qui vacille.
#
#    En listant d'emblée les 5 IP de CP prévues par le plan d'adressage (les mêmes que
#    les certSANs de cluster-up.sh), la configuration de cp1 est déjà la bonne le jour
#    où cp2 et cp3 apparaissent. Un pair qui n'existe pas encore ne coûte qu'un paquet
#    VRRP sans réponse toutes les secondes.
peers=""
for i in 1 2 3 4 5; do
  ip="${NETWORK}.$((CP_IP_START + (i - 1) * CP_IP_STEP))"
  [ "$ip" = "$NODE_IP" ] && continue
  peers="${peers}        ${ip}"$'\n'
done

# cp1 = 100, cp2 = 90, cp3 = 80. Le script de santé retire 30 : un cp1 dont l'apiserver
# est mort tombe à 70 et passe DERRIÈRE un cp2 sain (90), qui reprend la VIP.
priority=$((100 - (NODE_INDEX - 1) * 10))
[ "$priority" -lt 10 ] && priority=10

# La VIP ne doit vivre que là où l'apiserver LOCAL répond. L'endpoint est accessible
# en anonyme : le ClusterRoleBinding `system:public-info-viewer`, posé par kubeadm,
# ouvre /healthz, /livez et /readyz à `system:unauthenticated`. Aucun credential à
# distribuer au script de santé, donc.
#
# ⚠️ `/livez/ping` et NON `/livez`. Contrairement à ce qu'on croit souvent, `/livez`
#    AGRÈGE tous les checks enregistrés — dont `etcd`. Or `kubeadm join --control-plane`
#    rend etcd temporairement indisponible en passant de 1 à 2 membres (kubeadm le
#    documente lui-même). Un `/livez` global échouant plus de `fall x interval` = 9 s
#    ferait tomber cp1 à 70 pendant que cp2 vient de passer à 90 : LA VIP SAUTERAIT SUR
#    CP2 AU MILIEU DU BOOTSTRAP. `/livez/ping` est le sous-check trivial « le processus
#    répond », sans aucune dépendance à un backend : c'est exactement ce qu'on veut
#    savoir pour décider qui porte la VIP.
#
# Tant que le cluster n'existe pas, le test échoue sur TOUS les control planes : ils
# perdent 30 points chacun, l'ordre relatif est préservé, et la VIP est quand même
# portée. C'est exactement ce qu'il faut pour que `kubeadm init` la trouve en place.
#
# Le script vit dans /etc/keepalived et NON dans /usr/local/bin : avec
# `enable_script_security`, keepalived inspecte CHAQUE composant du chemin et désactive
# purement et simplement le track_script si un répertoire est group-writable avec un
# groupe non-root. Or /usr/local/bin devient `root:staff 2775` dès que
# /etc/staff-group-for-usr-local existe (cas d'un système migré depuis stretch). La
# bascule de VIP serait alors MORTE, sans autre trace qu'une ligne dans journalctl.
# /etc/keepalived est root:root par construction : le risque disparaît.
tee /etc/keepalived/check-apiserver.sh >/dev/null <<'EOF'
#!/bin/sh
curl -sfk --max-time 2 https://127.0.0.1:6443/livez/ping >/dev/null
EOF
chown root:root /etc/keepalived/check-apiserver.sh
chmod 0755 /etc/keepalived/check-apiserver.sh

# Pas de bloc `authentication` : l'authentification VRRPv2 transmet un mot de passe en
# clair et n'apporte aucune sécurité réelle. Ici la frontière de confiance est le réseau
# host-only lui-même. Pour cohabiter avec un AUTRE lab keepalived sur le même réseau,
# c'est VRRP_ROUTER_ID (lab.env) qu'il faut changer, pas un mot de passe.
tee /etc/keepalived/keepalived.conf >/dev/null <<EOF
global_defs {
    enable_script_security
    script_user root
}

vrrp_script chk_apiserver {
    script "/etc/keepalived/check-apiserver.sh"
    interval 3
    timeout 2
    fall 3
    rise 2
    weight -30
}

vrrp_instance VI_K8S {
    state BACKUP
    interface ${HOSTONLY_IF}
    virtual_router_id ${VRRP_ROUTER_ID}
    priority ${priority}
    advert_int 1
    unicast_src_ip ${NODE_IP}
$([ -n "$peers" ] && printf '    unicast_peer {\n%s    }\n' "$peers")
    virtual_ipaddress {
        ${VIP}/24
    }
    track_script {
        chk_apiserver
    }
}
EOF

systemctl enable keepalived >/dev/null 2>&1 || true
systemctl restart keepalived
else
log "[8/8] keepalived — ignoré (node de rôle '${NODE_ROLE}')"
fi

# ============================================================================
log "Node prêt pour kubeadm."
echo "    rôle       : ${NODE_ROLE}"
echo "    IP node    : ${NODE_IP}  (interface ${HOSTONLY_IF})"
echo "    kubeadm    : $(kubeadm version -o short 2>/dev/null || echo '?')"
echo "    containerd : $(containerd --version 2>/dev/null | awk '{print $3}' || echo '?')"
