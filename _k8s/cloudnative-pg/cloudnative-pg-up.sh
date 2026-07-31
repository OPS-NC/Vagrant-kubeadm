#!/usr/bin/env bash
#
# cloudnative-pg-up.sh — installe l'opérateur CloudNativePG + un cluster PostgreSQL HA
# de démo (3 nœuds, 1Gi RWO sur Longhorn) sur le cluster kubeadm.
#
# Ordre :
#   1. Opérateur CloudNativePG   (CRD Cluster + contrôleur) via Helm
#   2. Cluster de démo `pg-demo` (3 instances sur Longhorn)
#
# Prérequis : Longhorn installé (StorageClass `longhorn`), cf. _k8s/longhorn/.
# Idempotent : `helm upgrade --install` + `kubectl apply`. Relançable sans casse.
# À lancer depuis la racine du dépôt : ./_k8s/cloudnative-pg/cloudnative-pg-up.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"
HERE="_k8s/cloudnative-pg"

# --- Versions épinglées (overridables par variable d'env) -------------------
CNPG_VERSION="${CNPG_VERSION:-0.29.0}"          # app v1.30.0

for bin in kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable." >&2; exit 1; }
done
kubectl get --raw='/readyz' >/dev/null 2>&1 || { echo "ERREUR : apiserver injoignable (KUBECONFIG=${KUBECONFIG})." >&2; exit 1; }
kubectl get storageclass longhorn-r1 >/dev/null 2>&1 || { echo "ERREUR : StorageClass 'longhorn-r1' absente. Installe Longhorn puis applique le socle : kubectl apply -f _k8s/longhorn/longhorn-r1-storageclass.yaml" >&2; exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ============================================================================
log "[1/2] Opérateur CloudNativePG ${CNPG_VERSION}"
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update cnpg >/dev/null
helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace \
  --version "${CNPG_VERSION}" \
  --values "${HERE}/values.yaml"
kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg --timeout=180s

log "[2/2] Cluster PostgreSQL de démo (3 nœuds, 1Gi RWO Longhorn)"
kubectl apply -f "${HERE}/cluster-demo.yaml"
echo "    attente du cluster en santé (provisioning + réplicas)..."
kubectl -n cnpg-demo wait --for=condition=Ready cluster/pg-demo --timeout=300s || true

# ============================================================================
log "CloudNativePG installé."
kubectl -n cnpg-demo get cluster pg-demo 2>/dev/null || true
echo "  Instances   : kubectl -n cnpg-demo get pods -l cnpg.io/cluster=pg-demo"
echo "  Services    : pg-demo-rw (primaire) / pg-demo-ro (réplicas) / pg-demo-r (tous)"
echo "  Identifiants: kubectl -n cnpg-demo get secret pg-demo-app -o jsonpath='{.data.uri}' | base64 -d"
echo "  Statut      : kubectl cnpg status pg-demo -n cnpg-demo   (plugin kubectl-cnpg)"
