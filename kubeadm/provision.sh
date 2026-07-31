#!/usr/bin/env bash
#
# provision.sh — préparation système d'un node, exécutée DANS la VM par Vagrant
# (cf. `node.vm.provision "shell"` du Vagrantfile). Ne bootstrape AUCUN cluster :
# à la fin de `vagrant up`, chaque VM est prête à recevoir un `kubeadm init/join`,
# et rien de plus. Le bootstrap est piloté depuis l'hôte par kubeadm/cluster-up.sh.
#
# Ce que ce script pose, dans l'ordre (chaque étape suppose la précédente) :
#   1. /etc/hosts        résolution déterministe de tous les nodes du lab
#   2. prérequis noyau   swap coupé, modules, sysctl
#   3. paquets de base   dont open-iscsi/nfs-common (Longhorn) et conntrack (kube-proxy)
#   4. containerd        2.x (dépôt Docker) ou 1.7 (Debian), cgroup systemd
#   5. kubeadm/kubelet/kubectl  version épinglée puis `apt-mark hold`
#   6. images            pré-tirées, pour que `kubeadm init` ne télécharge plus rien
#   7. keepalived        VIP de l'API en VRRP — control planes uniquement
#
# Idempotent : relançable à volonté (`vagrant provision`).
#
# Variables reçues du Vagrantfile : NODE_NAME NODE_ROLE NODE_INDEX NODE_IP NETWORK
# VIP CP_IPS VRRP_ROUTER_ID K8S_VERSION K8S_APT_MINOR CONTAINERD_SOURCE
# REGISTRY_MIRROR HOSTS_ENTRIES
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

NODE_NAME="${NODE_NAME:-$(hostname)}"
NODE_ROLE="${NODE_ROLE:-worker}"
NODE_INDEX="${NODE_INDEX:-1}"
NODE_IP="${NODE_IP:?NODE_IP manquant (fourni par le Vagrantfile)}"
NETWORK="${NETWORK:-192.168.56}"
VIP="${VIP:-${NETWORK}.5}"
CP_IPS="${CP_IPS:-}"
VRRP_ROUTER_ID="${VRRP_ROUTER_ID:-51}"
K8S_VERSION="${K8S_VERSION:-1.36.3}"
K8S_APT_MINOR="${K8S_APT_MINOR:-v1.36}"
CONTAINERD_SOURCE="${CONTAINERD_SOURCE:-docker}"
REGISTRY_MIRROR="${REGISTRY_MIRROR:-}"
HOSTS_ENTRIES="${HOSTS_ENTRIES:-}"

log() { printf '\n\033[1;36m[%s] ==> %s\033[0m\n' "$NODE_NAME" "$*"; }

# ============================================================================
log "[1/7] Résolution des noms (/etc/hosts)"
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
log "[2/7] Prérequis noyau (swap, modules, sysctl)"

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
log "[3/7] Paquets de base"
apt-get update -qq
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
log "[4/7] containerd (source : ${CONTAINERD_SOURCE})"
case "$CONTAINERD_SOURCE" in
  docker)
    # containerd 2.x. Seule la branche 2.x implémente la méthode CRI `RuntimeConfig`
    # dont kubeadm se sert pour lire le cgroup driver du runtime. En 1.36 son absence
    # n'est qu'un avertissement de preflight, mais le repli disparaît en 1.37 : la
    # branche 1.7 de Debian est une impasse (containerd#11346 fermé sans merge).
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
      curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
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
log "[5/7] kubelet / kubeadm / kubectl ${K8S_VERSION} (dépôt ${K8S_APT_MINOR})"
# kubernetes.io ne publie que la forme `.list` classique (pas de deb822) : c'est
# celle qui est testée en amont, on ne s'en écarte pas.
if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_APT_MINOR}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
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
log "[6/7] Pré-tirage des images"
# Fait ici, PENDANT `vagrant up`, donc en parallèle sur toutes les VM. `kubeadm init`
# n'a alors plus rien à télécharger, ce qui retire la plus grosse source de timeouts
# du bootstrap (et rend le lab reconstructible hors-ligne).
if [ "$NODE_ROLE" = "controlplane" ]; then
  kubeadm config images pull --kubernetes-version "v${K8S_VERSION}" >/dev/null 2>&1 \
    || echo "    (pré-tirage partiel — kubeadm init retéléchargera au besoin)"
else
  # Un worker n'héberge ni apiserver, ni etcd, ni scheduler : seules `pause` et
  # `kube-proxy` lui servent. Tirer les 7 images gâcherait ~500 Mio par worker.
  for img in "$PAUSE_IMAGE" "registry.k8s.io/kube-proxy:v${K8S_VERSION}"; do
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
log "[7/7] keepalived — VIP ${VIP} sur ${HOSTONLY_IF} (VRRP)"

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
# le multicast est le premier truc à se comporter bizarrement. On connaît toutes les
# IP de control plane, autant les désigner explicitement.
peers=""
if [ -n "$CP_IPS" ]; then
  for ip in ${CP_IPS//,/ }; do
    [ "$ip" = "$NODE_IP" ] && continue
    peers="${peers}        ${ip}"$'\n'
  done
fi

# cp1 = 100, cp2 = 90, cp3 = 80. Le script de santé retire 30 : un cp1 dont l'apiserver
# est mort tombe à 70 et passe DERRIÈRE un cp2 sain (90), qui reprend la VIP.
priority=$((100 - (NODE_INDEX - 1) * 10))
[ "$priority" -lt 10 ] && priority=10

# Le VIP ne doit vivre que là où l'apiserver LOCAL répond. `/livez` est accessible en
# anonyme : le ClusterRoleBinding `system:public-info-viewer`, posé par kubeadm,
# l'ouvre à `system:unauthenticated`. Aucun credential à distribuer, donc.
# Tant que le cluster n'existe pas, le test échoue sur TOUS les control planes : ils
# perdent 30 points chacun, l'ordre relatif est préservé, et la VIP est quand même
# portée. C'est exactement ce qu'il faut pour que `kubeadm init` la trouve en place.
tee /usr/local/bin/check-apiserver.sh >/dev/null <<'EOF'
#!/bin/sh
curl -sfk --max-time 2 https://127.0.0.1:6443/livez >/dev/null
EOF
chmod 0755 /usr/local/bin/check-apiserver.sh

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
    script "/usr/local/bin/check-apiserver.sh"
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
log "[7/7] keepalived — ignoré (node de rôle '${NODE_ROLE}')"
fi

# ============================================================================
log "Node prêt pour kubeadm."
echo "    rôle       : ${NODE_ROLE}"
echo "    IP node    : ${NODE_IP}  (interface ${HOSTONLY_IF})"
echo "    kubeadm    : $(kubeadm version -o short 2>/dev/null || echo '?')"
echo "    containerd : $(containerd --version 2>/dev/null | awk '{print $3}' || echo '?')"
