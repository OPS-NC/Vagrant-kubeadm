#!/usr/bin/env bash
#
# cluster-up.sh — enchaîne les commandes kubeadm pour monter le cluster
# (init -> join des control planes -> join des workers -> kubeconfig) après `vagrant up`.
#
# À lancer depuis la racine du dépôt :
#     ./kubeadm/cluster-up.sh
#
# La topologie vient de lab.env (source unique partagée avec le Vagrantfile). Elle se
# surcharge ponctuellement par variable d'environnement :
#     CONTROL_PLANES=3 WORKERS=3 ./kubeadm/cluster-up.sh
#
# IDEMPOTENT, et c'est aussi la façon d'AGRANDIR le lab : ajoute des nodes dans lab.env,
# `vagrant up`, puis relance ce script — il saute ce qui est déjà en place et ne joint
# que les nouveaux nodes.
#
# Le script ne fait RIEN à l'intérieur des VM lui-même : il rend les configurations dans
# `_out/` (visible depuis les VM via le dossier synchronisé /vagrant) puis appelle
# kubeadm/node-init.sh et kubeadm/node-join.sh par `vagrant ssh`.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

# --- Topologie : source unique lab.env (partagée avec le Vagrantfile) -------
# Chargée SANS écraser une variable déjà exportée : la surcharge en ligne de commande
# reste prioritaire. Le nom de clé est validé avant tout `eval` — un lab.env bricolé
# ne doit pas pouvoir exécuter du code arbitraire.
if [ -f "${REPO_DIR}/lab.env" ]; then
  while IFS='=' read -r key val || [ -n "$key" ]; do
    case "$key" in ''|\#*) continue ;; esac
    case "$key" in [A-Za-z_]*) ;; *) continue ;; esac
    printf '%s' "$key" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$' || continue
    val="${val%%#*}"                                    # commentaire de fin de ligne
    val="$(printf '%s' "$val" | tr -d '[:space:]"'"'")" # espaces et guillemets
    eval ": \${$key:=\$val}"
  done < "${REPO_DIR}/lab.env"
fi

# --- Paramètres (défauts = filet de sécurité si lab.env est absent) ---------
# ⚠️ Ces défauts DOIVENT rester alignés sur ceux du Vagrantfile et de lab.env.example.
CONTROL_PLANES="${CONTROL_PLANES:-1}"
WORKERS="${WORKERS:-2}"
NETWORK="${NETWORK:-192.168.56}"
VIP="${VIP:-${NETWORK}.5}"
CLUSTER_NAME="${CLUSTER_NAME:-kubeadm-lab}"
NODE_PREFIX="${NODE_PREFIX:-k8s}"
K8S_VERSION="${K8S_VERSION:-1.36.3}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
CNI="${CNI:-cilium}"
KUBE_PROXY_REPLACEMENT="${KUBE_PROXY_REPLACEMENT:-true}"
UNTAINT_CP="${UNTAINT_CP:-auto}"
CP_IP_START="${CP_IP_START:-10}"  ; CP_IP_STEP="${CP_IP_STEP:-10}"
WK_IP_START="${WK_IP_START:-101}" ; WK_IP_STEP="${WK_IP_STEP:-1}"
OUT="${OUT:-_out}"

WAIT_API="${WAIT_API:-600}"   # apiserver joignable après `kubeadm init`

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# --- Pré-requis -------------------------------------------------------------
for bin in vagrant kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable dans le PATH." >&2; exit 1; }
done

# --- Cohérence de la configuration ------------------------------------------
case "$CNI" in cilium|calico|flannel|none) ;; *)
  echo "ERREUR : CNI='${CNI}' inconnu (cilium|calico|flannel|none)." >&2 ; exit 1 ;; esac

KUBE_PROXY_REPLACEMENT="$(printf '%s' "$KUBE_PROXY_REPLACEMENT" | tr '[:upper:]' '[:lower:]')"
case "$KUBE_PROXY_REPLACEMENT" in true|false) ;; *)
  echo "ERREUR : KUBE_PROXY_REPLACEMENT='${KUBE_PROXY_REPLACEMENT}' inconnu (true|false)." >&2 ; exit 1 ;; esac

# Sans kube-proxy ET sans remplaçant, AUCUN Service ne fonctionne — pas même
# l'accès de CoreDNS à l'API. Seul Cilium sait le remplacer dans ce lab, donc on refuse
# la combinaison au lieu de livrer un cluster silencieusement inutilisable.
if [ "$KUBE_PROXY_REPLACEMENT" = "true" ] && [ "$CNI" != "cilium" ]; then
  cat >&2 <<EOF
ERREUR : KUBE_PROXY_REPLACEMENT=true exige CNI=cilium (actuellement CNI=${CNI}).

  Avec cette combinaison, cluster-up.sh sauterait l'installation de kube-proxy alors
  que ${CNI} ne sait pas le remplacer : plus aucune ClusterIP ne répondrait.

  Deux issues, dans lab.env :
    - CNI=cilium                     (garder le remplacement eBPF, défaut du dépôt)
    - KUBE_PROXY_REPLACEMENT=false   (garder kube-proxy et ${CNI})
EOF
  exit 1
fi

if [ "$CONTROL_PLANES" -lt 1 ]; then
  echo "ERREUR : CONTROL_PLANES=${CONTROL_PLANES} — il en faut au moins 1." >&2 ; exit 1
fi
if [ $((CONTROL_PLANES % 2)) -eq 0 ]; then
  echo "ERREUR : CONTROL_PLANES=${CONTROL_PLANES} est PAIR. etcd exige un nombre impair" >&2
  echo "         pour tenir un quorum utile (1, 3, 5) : avec 2 membres, la perte d'un" >&2
  echo "         seul node fige l'API." >&2
  exit 1
fi

# --- Calcul des IP et des noms ----------------------------------------------
cp_names=() ; cp_ips=() ; wk_names=() ; wk_ips=()
for ((i = 1; i <= CONTROL_PLANES; i++)); do
  cp_names+=("${NODE_PREFIX}-cp${i}")
  cp_ips+=("${NETWORK}.$((CP_IP_START + (i - 1) * CP_IP_STEP))")
done
for ((i = 1; i <= WORKERS; i++)); do
  wk_names+=("${NODE_PREFIX}-w${i}")
  wk_ips+=("${NETWORK}.$((WK_IP_START + (i - 1) * WK_IP_STEP))")
done
first_cp="${cp_names[0]}" ; first_cp_ip="${cp_ips[0]}"

echo "==> Topologie  : ${CONTROL_PLANES} control plane(s) + ${WORKERS} worker(s)"
echo "    control    : $(IFS=' '; echo "${cp_names[*]}") -> $(IFS=' '; echo "${cp_ips[*]}")"
echo "    workers    : ${wk_names[*]:-aucun} -> ${wk_ips[*]:-}"
echo "==> API        : https://${VIP}:6443   (VIP keepalived)"
echo "==> Kubernetes : v${K8S_VERSION} — CNI=${CNI}, kube-proxy $([ "$KUBE_PROXY_REPLACEMENT" = true ] && echo 'REMPLACÉ par Cilium (eBPF)' || echo 'installé')"

# --- Les VM tournent-elles ? -------------------------------------------------
# Diagnostiquer ici coûte une seconde ; le diagnostiquer plus tard, c'est un
# `vagrant ssh` qui part en timeout au milieu d'un `join` à moitié fait.
manquantes=()
for n in "${cp_names[@]}" "${wk_names[@]:-}"; do
  [ -z "$n" ] && continue
  etat="$(vagrant status "$n" --machine-readable 2>/dev/null \
           | awk -F, '$3 == "state" {print $4; exit}')"
  [ "$etat" = "running" ] || manquantes+=("${n} (${etat:-inexistante})")
done
if [ "${#manquantes[@]}" -gt 0 ]; then
  echo "ERREUR : ces VM ne tournent pas : ${manquantes[*]}" >&2
  echo "         Lance d'abord :  vagrant up" >&2
  exit 1
fi

mkdir -p "$OUT"

# Exécute une commande dans une VM. `-q` et LogLevel=ERROR pour que la sortie du
# script reste lisible (sinon OpenSSH commente chaque connexion).
sur_node() {
  local node="$1" ; shift
  vagrant ssh "$node" -c "$*" -- -q -o LogLevel=ERROR
}

# Rendu d'un modèle : substitution des marqueurs @NOM@. `@CERT_SANS@` est une LISTE,
# donc traitée à part (`r` insère le fichier après la ligne, `d` supprime le marqueur).
rendre() {
  local tpl="$1" dest="$2" node_name="$3" node_ip="$4"
  sed -e "s|@NODE_NAME@|${node_name}|g" \
      -e "s|@NODE_IP@|${node_ip}|g" \
      -e "s|@VIP@|${VIP}|g" \
      -e "s|@K8S_VERSION@|${K8S_VERSION}|g" \
      -e "s|@CLUSTER_NAME@|${CLUSTER_NAME}|g" \
      -e "s|@POD_CIDR@|${POD_CIDR}|g" \
      -e "s|@SERVICE_CIDR@|${SERVICE_CIDR}|g" \
      -e "s|@TOKEN@|${TOKEN:-}|g" \
      -e "s|@CA_HASH@|${CA_HASH:-}|g" \
      -e "s|@CERT_KEY@|${CERT_KEY:-}|g" \
      -e "/@CERT_SANS@/r ${OUT}/certsans.txt" \
      -e "/@CERT_SANS@/d" \
      "$tpl" >"$dest"
}

# ============================================================================
log "[1/5] Rendu de la configuration kubeadm (${OUT}/)"

# certSANs : tout ce par quoi on peut légitimement joindre l'apiserver. Il faut les
# poser MAINTENANT — un SAN oublié ne s'ajoute qu'en régénérant les certificats. On y
# met TOUTES les IP de control plane possibles, y compris celles de nodes pas encore
# créés, pour qu'agrandir le cluster plus tard ne demande aucune régénération.
{
  echo "    - ${VIP}"
  echo "    - kubernetes-api"
  for ((i = 1; i <= 5; i++)); do
    echo "    - ${NETWORK}.$((CP_IP_START + (i - 1) * CP_IP_STEP))"
  done
  for n in "${cp_names[@]}"; do echo "    - ${n}"; done
  echo "    - 127.0.0.1"
  echo "    - localhost"
} >"${OUT}/certsans.txt"

rendre kubeadm/templates/kubeadm-init.yaml.tpl "${OUT}/kubeadm-init.yaml" \
       "$first_cp" "$first_cp_ip"
echo "    ${OUT}/kubeadm-init.yaml  (${first_cp} @ ${first_cp_ip})"

# ============================================================================
log "[2/5] kubeadm init sur ${first_cp}"
# `--skip-phases=addon/kube-proxy` plutôt que le champ déclaratif `proxy.disabled` de
# v1beta4 : le drapeau est éprouvé sur toutes les versions, et c'est celui que la doc
# Cilium documente. Le résultat est identique.
skip=""
[ "$KUBE_PROXY_REPLACEMENT" = "true" ] && skip="addon/kube-proxy"
sur_node "$first_cp" "sudo SKIP_PHASES='${skip}' bash /vagrant/kubeadm/node-init.sh"

[ -f "${OUT}/join.env" ] || { echo "ERREUR : ${OUT}/join.env absent — le init a échoué." >&2; exit 1; }
# shellcheck disable=SC1090
. "${OUT}/join.env"
: "${TOKEN:?token de jonction absent}" "${CA_HASH:?empreinte CA absente}" "${CERT_KEY:?clé de certificats absente}"

# --- kubeconfig sur l'hôte ---------------------------------------------------
# Rien à copier : node-init.sh a écrit admin.conf dans le dossier synchronisé.
cp -f "${OUT}/admin.conf" "${REPO_DIR}/kubeconfig"
chmod 0600 "${REPO_DIR}/kubeconfig"
export KUBECONFIG="${REPO_DIR}/kubeconfig"

# L'apiserver doit répondre PAR LA VIP avant de joindre quoi que ce soit : c'est
# l'adresse que les autres nodes utiliseront, et c'est le seul vrai test que keepalived
# fait bien son travail.
printf '    - attente de https://%s:6443 ' "$VIP"
fin=$((SECONDS + WAIT_API))
until kubectl get --raw='/readyz' >/dev/null 2>&1; do
  if [ "$SECONDS" -ge "$fin" ]; then
    printf ' ÉCHEC (%ss)\n' "$WAIT_API"
    cat >&2 <<EOF
ERREUR : l'apiserver ne répond pas sur la VIP ${VIP} après ${WAIT_API}s.

  Les deux causes, par fréquence :
    1. keepalived ne porte pas la VIP. À vérifier depuis l'hôte :
         vagrant ssh ${first_cp} -c "ip -4 addr show | grep ${VIP}"
         vagrant ssh ${first_cp} -c "sudo systemctl status keepalived"
    2. l'apiserver lui-même ne démarre pas :
         vagrant ssh ${first_cp} -c "sudo crictl ps -a | grep apiserver"
         vagrant ssh ${first_cp} -c "sudo journalctl -u kubelet -n 50"
EOF
    exit 1
  fi
  printf '.' ; sleep 5
done
echo ' OK'

# ============================================================================
if [ "$CONTROL_PLANES" -gt 1 ]; then
log "[3/5] Jonction des control planes secondaires"
# UN SEUL À LA FOIS, et c'est structurel : chaque jonction ajoute un membre à etcd, et
# etcd n'accepte qu'un changement d'appartenance à la fois. En parallèle, le second
# échoue avec une erreur de quorum passablement obscure.
for ((i = 2; i <= CONTROL_PLANES; i++)); do
  name="${cp_names[$((i-1))]}" ; ip="${cp_ips[$((i-1))]}"
  rendre kubeadm/templates/kubeadm-join-cp.yaml.tpl "${OUT}/join-${name}.yaml" "$name" "$ip"
  echo "    - ${name} (${ip})"
  sur_node "$name" "sudo NODE_NAME='${name}' bash /vagrant/kubeadm/node-join.sh"
  # On attend que le nouveau membre etcd soit vu par l'API avant d'enchaîner.
  kubectl wait --for=condition=Ready=false --timeout=10s "node/${name}" >/dev/null 2>&1 || true
done
else
log "[3/5] Control plane unique — aucune jonction de CP"
fi

# ============================================================================
if [ "$WORKERS" -gt 0 ]; then
log "[4/5] Jonction des ${WORKERS} worker(s)"
for ((i = 1; i <= WORKERS; i++)); do
  name="${wk_names[$((i-1))]}" ; ip="${wk_ips[$((i-1))]}"
  rendre kubeadm/templates/kubeadm-join-worker.yaml.tpl "${OUT}/join-${name}.yaml" "$name" "$ip"
  echo "    - ${name} (${ip})"
  sur_node "$name" "sudo NODE_NAME='${name}' bash /vagrant/kubeadm/node-join.sh"
done
else
log "[4/5] WORKERS=0 — aucun worker à joindre"
fi

# ============================================================================
log "[5/5] Finalisation"

# --- Taint des control planes ------------------------------------------------
# `auto` : on ne déteinte que s'il n'y a aucun worker, sinon plus rien ne pourrait
# se planifier. C'est le réglage qui rend WORKERS=0 réellement utilisable.
untaint="$(printf '%s' "$UNTAINT_CP" | tr '[:upper:]' '[:lower:]')"
case "$untaint" in
  auto)  [ "$WORKERS" -eq 0 ] && untaint=true || untaint=false ;;
  true|false) ;;
  *) echo "    /!\\ UNTAINT_CP='${UNTAINT_CP}' inconnu (auto|true|false) — ignoré." >&2 ; untaint=false ;;
esac
if [ "$untaint" = "true" ]; then
  echo "    - retrait du taint control-plane (les pods pourront s'y planifier)"
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
fi

# --- Étiquetage des workers ---------------------------------------------------
# kubeadm ne pose AUCUN rôle sur un worker : `kubectl get nodes` affiche `<none>` dans
# la colonne ROLES, ce qui déroute et casse les sélecteurs `node-role.kubernetes.io/worker`.
for name in "${wk_names[@]:-}"; do
  [ -z "$name" ] && continue
  kubectl label node "$name" node-role.kubernetes.io/worker= --overwrite >/dev/null 2>&1 || true
done

# --- Fiche de faits du cluster, relue par les scripts _k8s/ -------------------
# L'interface host-only est DÉTECTÉE dans la VM (cf. provision.sh) plutôt que devinée :
# Debian 13 utilise les noms prédictibles (`enp0s8`) mais certaines box gardent `eth1`,
# et Cilium a besoin du vrai nom pour son annonce L2.
hostonly_if="$(sur_node "$first_cp" "sed -n 's/^HOSTONLY_IF=//p' /etc/kubeadm-lab/node.env" 2>/dev/null \
                | tr -d '\r[:space:]')"
hostonly_if="${hostonly_if:-eth1}"
cat >"${OUT}/cluster.env" <<EOF
# Généré par kubeadm/cluster-up.sh — relu par les scripts _k8s/*-up.sh.
CLUSTER_NAME=${CLUSTER_NAME}
K8S_VERSION=${K8S_VERSION}
VIP=${VIP}
API_ENDPOINT=${VIP}:6443
POD_CIDR=${POD_CIDR}
SERVICE_CIDR=${SERVICE_CIDR}
CNI=${CNI}
KUBE_PROXY_REPLACEMENT=${KUBE_PROXY_REPLACEMENT}
HOSTONLY_IF=${hostonly_if}
CONTROL_PLANES=${CONTROL_PLANES}
WORKERS=${WORKERS}
EOF
echo "    - ${OUT}/cluster.env (interface host-only détectée : ${hostonly_if})"

# ============================================================================
echo
echo "================================================================"
echo " Cluster prêt."
echo "   export KUBECONFIG=${REPO_DIR}/kubeconfig"
echo "   kubectl get nodes -o wide"
echo "================================================================"
kubectl get nodes -o wide 2>/dev/null || true
echo
if [ "$CNI" = "none" ]; then
  echo " CNI=none : les nodes resteront NotReady tant que TU n'auras pas posé de CNI."
else
  echo " Les nodes sont NotReady : c'est NORMAL, aucun CNI n'est encore installé."
  echo " Étape suivante — la couche applicative (CNI ${CNI}, Gateway, metrics, TLS) :"
  echo "     ./_k8s/platform-up.sh"
fi
