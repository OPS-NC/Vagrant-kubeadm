#!/usr/bin/env bash
#
# cilium-up.sh — installe Cilium (CNI + IP LoadBalancer + annonce L2) sur un cluster
# kubeadm bootstrapé SANS CNI (`./kubeadm/cluster-up.sh` avec CNI=cilium, ou CNI=none si
# tu pilotes tout à la main : dans les deux cas kubeadm n'installe aucun réseau pod, les
# nodes sont NotReady tant que ce script n'est pas passé).
#
# Fait deux choses (le 2e suppose le 1er) :
#   1. Cilium en Helm : CNI (=> nodes Ready), remplacement eBPF de kube-proxy selon
#      KUBE_PROXY_REPLACEMENT, annonce L2 activée, et interface host-only épinglée
#      (sinon Cilium prend la carte NAT 10.0.2.15, identique sur chaque VM => trafic
#      cross-node et DNS cassés).
#   2. Pool L2 : CiliumLoadBalancerIPPool (.200-.230) + CiliumL2AnnouncementPolicy (ARP).
#
# Appelé par _k8s/platform-up.sh (étape 1), mais lançable seul :
#   ./_k8s/cilium/cilium-up.sh
# Idempotent : `helm upgrade --install` + `kubectl apply`.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"

# --- Lecture des paramètres du lab -------------------------------------------
# Deux sources, dans cet ordre :
#   1. `_out/cluster.env`, écrit par kubeadm/cluster-up.sh à la fin du bootstrap : il
#      porte des valeurs DÉTECTÉES sur le cluster réel (nom d'interface host-only, CIDR
#      effectivement passé à kubeadm) ;
#   2. `lab.env`, qui n'exprime qu'une INTENTION (le fichier peut avoir été édité APRÈS
#      le bootstrap, auquel cas il ment sur ce qui tourne).
# `sed -n s///p` et JAMAIS `grep` : sans correspondance `grep` renvoie 1 et, sous
# `set -e` + `pipefail`, tuerait le script. Le `|| true` couvre l'absence du fichier
# (où `sed` sort en 2).
lire_cluster_env() {
  sed -n "s/^[[:space:]]*$1=//p" \
    "${REPO_DIR}/_out/cluster.env" 2>/dev/null | head -n1 | tr -d " \"'" || true
}
lire_lab_env() {
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" \
    "${REPO_DIR}/lab.env" 2>/dev/null | head -n1 \
    | sed 's/[[:space:]][[:space:]]*#.*$//' | tr -d " \"'" || true
}
# Une vraie variable d'environnement reste prioritaire sur les deux fichiers.
lire_param() {  # lire_param NOM DEFAUT
  local v="${!1:-}"
  [ -z "$v" ] && v="$(lire_cluster_env "$1")"
  [ -z "$v" ] && v="$(lire_lab_env "$1")"
  printf '%s' "${v:-$2}"
}

CILIUM_VERSION="$(lire_param CILIUM_VERSION 1.20.0)"

# Plage d'IP LoadBalancer (pas dans cluster.env : c'est une pure intention).
LB_POOL_START="${LB_POOL_START:-$(lire_lab_env LB_POOL_START)}"
LB_POOL_START="${LB_POOL_START:-192.168.56.200}"
LB_POOL_END="${LB_POOL_END:-$(lire_lab_env LB_POOL_END)}"
LB_POOL_END="${LB_POOL_END:-192.168.56.230}"

# Remplacement de kube-proxy : DOIT refléter ce qui a réellement été fait au bootstrap.
# `kubeadm init` a tourné avec `--skip-phases=addon/kube-proxy` quand la valeur est
# `true` : il n'y a alors AUCUN kube-proxy dans le cluster, et Cilium doit prendre le
# relais en eBPF. Se tromper de valeur casse tous les Services du cluster.
KUBE_PROXY_REPLACEMENT="$(lire_param KUBE_PROXY_REPLACEMENT true)"
KUBE_PROXY_REPLACEMENT="$(printf '%s' "$KUBE_PROXY_REPLACEMENT" | tr '[:upper:]' '[:lower:]')"
case "$KUBE_PROXY_REPLACEMENT" in
  true|false) ;;
  *) echo "ERREUR : KUBE_PROXY_REPLACEMENT='${KUBE_PROXY_REPLACEMENT}' inconnu (true|false)." >&2; exit 1 ;;
esac

# Point de contact de l'apiserver pour l'agent Cilium. On y met la VIP keepalived
# (`controlPlaneEndpoint` du cluster), PAS l'IP réelle de cp1 :
#   - la VIP survit à la perte de cp1 (VRRP la déplace sur cp2/cp3), l'IP de cp1 non ;
#   - c'est déjà l'adresse figée dans les certificats et les kubeconfig, donc la seule
#     que le certificat de l'apiserver couvre à coup sûr.
VIP="$(lire_param VIP 192.168.56.5)"

# CIDR des pods déclaré à kubeadm (`networking.podSubnet`).
POD_CIDR="$(lire_param POD_CIDR 10.244.0.0/16)"

# Interface host-only, DÉTECTÉE dans la VM par cluster-up.sh. Debian 13 utilise les noms
# prédictibles (`enp0s8`) mais certaines box Vagrant gardent `eth1` : ne rien coder en dur.
HOSTONLY_IF="$(lire_param HOSTONLY_IF eth1)"

for bin in kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable." >&2; exit 1; }
done
kubectl get --raw='/readyz' >/dev/null 2>&1 || { echo "ERREUR : apiserver injoignable (KUBECONFIG=${KUBECONFIG})." >&2; exit 1; }

# --- Garde-fou : un CNI déjà en place -----------------------------------------
# Poser Cilium par-dessus flannel donne deux CNI concurrents et un réseau pod cassé.
# Le cas arrive tout seul quand `lab.env` a été édité APRÈS le bootstrap (le cluster a
# été monté avec CNI=flannel, `_k8s/platform-up.sh` a posé flannel, et on relance
# maintenant Cilium à la main) : on refuse.
# On cherche par motif et non par nom exact : le DaemonSet s'appelle `kube-flannel-ds`
# dans le namespace `kube-flannel` chez l'upstream, mais un chart peut le renommer.
flannel_ds="$(kubectl get daemonsets -A -o name 2>/dev/null | grep -i flannel || true)"
if [ -n "$flannel_ds" ]; then
  cat >&2 <<EOF
ERREUR : flannel est déjà installé (${flannel_ds}).
  Ce cluster tourne avec CNI=flannel (posé par _k8s/platform-up.sh) : ajouter Cilium
  par-dessus casse le réseau pod. Changer de CNI à chaud n'est PAS supporté.
  Pour repartir sur Cilium :
    1. mettre CNI=cilium dans lab.env (le défaut du dépôt) ;
    2. ./kubeadm/cluster-reset.sh && ./kubeadm/cluster-up.sh
       (ou vagrant destroy && vagrant up && ./kubeadm/cluster-up.sh)
  Cf. _k8s/cilium/README.md.
EOF
  exit 1
fi

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ============================================================================
log "Cilium ${CILIUM_VERSION} (CNI + L2, interface host-only ${HOSTONLY_IF})"
echo "    kube-proxy : $([ "$KUBE_PROXY_REPLACEMENT" = true ] && echo 'REMPLACÉ en eBPF' || echo 'conservé (Cilium par-dessus)')"
echo "    pod CIDR   : ${POD_CIDR}   apiserver : ${VIP}:6443"
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium >/dev/null
# Aucune valeur « spéciale OS » ici : sur Debian les défauts du chart sont les bons.
# (Les `cgroup.autoMount.enabled=false`, `cgroup.hostRoot` et `securityContext.capabilities.*`
#  que documente Cilium sont propres à Talos — sur Debian ils sont nuisibles : le chart
#  monte lui-même le cgroup2 et calcule les capabilities dont l'agent a besoin.)
helm upgrade --install cilium cilium/cilium -n kube-system --create-namespace \
  --version "${CILIUM_VERSION}" \
  --set envoy.enabled=false \
  --set kubeProxyReplacement="${KUBE_PROXY_REPLACEMENT}" \
  --set k8sServiceHost="${VIP}" \
  --set k8sServicePort=6443 \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList="{${POD_CIDR}}" \
  --set ipam.operator.clusterPoolIPv4MaskSize=24 \
  --set l2announcements.enabled=true \
  --set externalIPs.enabled=true \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set bandwidthManager.enabled=true \
  --set devices="${HOSTONLY_IF}"
echo "    attente des nodes Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

log "Pool L2 Cilium (IP LoadBalancer ${LB_POOL_START}-${LB_POOL_END} + annonce ARP sur ${HOSTONLY_IF})"
# Le manifeste porte les valeurs par défaut du lab ; on les remplace par celles du lab
# réel (plage de lab.env, interface détectée dans cluster.env).
# La 1re IP de la plage est celle que prendra le Gateway Envoy : c'est la cible du
# DNS wildcard `*.<LAB_DOMAIN>` (cf. README.md §5).
sed -e "s/192\.168\.56\.200/${LB_POOL_START}/g" \
    -e "s/192\.168\.56\.230/${LB_POOL_END}/g" \
    -e "s/enp0s8/${HOSTONLY_IF}/g" \
    _k8s/cilium/cilium-l2.yml | kubectl apply -f -

log "Cilium installé (CNI + pool L2)."
echo "  Diagnostic : kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose"
