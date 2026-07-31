#!/usr/bin/env bash
#
# cluster-reset.sh — défait le cluster (`kubeadm reset`) sur tous les nodes, SANS
# détruire les VM. On repart d'un `vagrant up` déjà fait : les paquets, containerd et
# keepalived restent en place, seul l'état Kubernetes disparaît.
#
#     ./kubeadm/cluster-reset.sh          # demande confirmation
#     ./kubeadm/cluster-reset.sh --yes    # sans confirmation
#
# Quand s'en servir plutôt que `vagrant destroy` :
#   - rejouer un bootstrap raté sans repayer 10 minutes de création de VM ;
#   - changer POD_CIDR, SERVICE_CIDR, le CNI ou la VIP (tous figés au `init`).
#
# ⚠️ DESTRUCTIF : etcd, les certificats et toutes les charges du cluster sont perdus.
#    Ce qui vit dans un PersistentVolume adossé au disque du node l'est aussi.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

if [ -f "${REPO_DIR}/lab.env" ]; then
  while IFS='=' read -r key val || [ -n "$key" ]; do
    case "$key" in ''|\#*) continue ;; esac
    printf '%s' "$key" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$' || continue
    val="${val%%#*}"
    val="$(printf '%s' "$val" | tr -d '[:space:]"'"'")"
    eval ": \${$key:=\$val}"
  done < "${REPO_DIR}/lab.env"
fi

CONTROL_PLANES="${CONTROL_PLANES:-1}"
WORKERS="${WORKERS:-2}"
NODE_PREFIX="${NODE_PREFIX:-k8s}"
OUT="${OUT:-_out}"

command -v vagrant >/dev/null 2>&1 || { echo "ERREUR : 'vagrant' introuvable." >&2; exit 1; }

nodes=()
for ((i = 1; i <= CONTROL_PLANES; i++)); do nodes+=("${NODE_PREFIX}-cp${i}"); done
for ((i = 1; i <= WORKERS;        i++)); do nodes+=("${NODE_PREFIX}-w${i}"); done

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# --- Confirmation ------------------------------------------------------------
if [ "${1:-}" != "--yes" ]; then
  cat <<EOF
⚠️  Ceci va exécuter 'kubeadm reset' sur : ${nodes[*]}

    etcd, les certificats et toutes les charges du cluster seront PERDUS.
    Les VM, elles, ne sont pas détruites.

EOF
  printf "Confirmer ? (tape 'oui') : "
  read -r reponse
  [ "$reponse" = "oui" ] || { echo "Annulé." ; exit 0 ; }
fi

# --- Reset, workers d'abord --------------------------------------------------
# Les workers avant les control planes : un worker qui se retire pendant que l'API
# répond encore se désinscrit proprement, au lieu de laisser un objet Node fantôme.
for ((i = ${#nodes[@]} - 1; i >= 0; i--)); do
  node="${nodes[$i]}"
  # `|| true` : sans lui, un `vagrant status` en erreur tuerait le reset sous `set -e`
  # au lieu de simplement signaler la VM comme absente et de passer à la suivante.
  etat="$(vagrant status "$node" --machine-readable 2>/dev/null \
           | awk -F, '$3 == "state" {print $4; exit}' || true)"
  if [ "$etat" != "running" ]; then
    echo "    - ${node} : ignorée (${etat:-inexistante})"
    continue
  fi
  log "reset de ${node}"
  vagrant ssh "$node" -c "sudo bash /vagrant/kubeadm/node-reset.sh" -- -q -o LogLevel=ERROR \
    || echo "    /!\\ reset partiel sur ${node} — poursuite"
done

# --- Nettoyage côté hôte -----------------------------------------------------
log "Nettoyage de l'hôte"
rm -rf "${REPO_DIR:?}/${OUT}"
rm -f  "${REPO_DIR}/kubeconfig"
echo "    ${OUT}/ et kubeconfig supprimés"

echo
echo "================================================================"
echo " Cluster défait. Les VM tournent toujours."
echo "   Pour remonter un cluster :  ./kubeadm/cluster-up.sh"
echo "================================================================"
