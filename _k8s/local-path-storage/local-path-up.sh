#!/usr/bin/env bash
#
# local-path-up.sh — installe Rancher local-path-provisioner : une StorageClass
# `local-path` PAR DÉFAUT qui provisionne des PV sur le disque local des workers
# (dossier /opt/local-path-provisioner). Stockage NODE-LOCAL, sans réplication :
# survit au redémarrage d'un pod, perdu si le node meurt. C'est l'alternative « sans
# Longhorn » pour les addons de ce lab (CloudNativePG, etc.).
#
# Idempotent : `kubectl apply`. Relançable sans casse.
# À lancer depuis la racine du dépôt : ./_k8s/local-path-storage/local-path-up.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"
HERE="_k8s/local-path-storage"

command -v kubectl >/dev/null 2>&1 || { echo "ERREUR : 'kubectl' introuvable." >&2; exit 1; }
kubectl get --raw='/readyz' >/dev/null 2>&1 || { echo "ERREUR : apiserver injoignable (KUBECONFIG=${KUBECONFIG})." >&2; exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ============================================================================
log "local-path-provisioner (/opt/local-path-provisioner, chemin amont)"
kubectl apply -f "${HERE}/local-path-storage.yaml"
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=120s

# ============================================================================
log "Installé."
echo "  StorageClass : $(kubectl get storageclass local-path -o jsonpath='{.metadata.name}{" (défaut="}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{")"}' 2>/dev/null)"
echo "  Test         : kubectl create -f - <<'EOF'"
echo "    (un PVC storageClassName: local-path -> Bound dès qu'un pod le consomme)"
echo "  Chemin hôte  : /opt/local-path-provisioner sur le worker qui héberge le PV"
echo "                 (vagrant ssh k8s-w1 -c 'sudo ls -l /opt/local-path-provisioner')"
