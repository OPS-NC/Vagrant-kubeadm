#!/usr/bin/env bash
#
# trivy-operator-up.sh — installe Trivy Operator (scanner de sécurité continu) sur le
# cluster kubeadm, et branche ses rapports dans l'UI Policy Reporter déjà déployée par
# l'addon kyverno/.
#
# Ordre :
#   1. Trivy Operator     scanne images/configs/secrets/RBAC → CRDs de rapport
#   2. Policy Reporter     helm upgrade pour activer le plugin trivy (UI unifiée)
#
# Prérequis : l'addon kyverno/ doit être installé (Policy Reporter fournit l'UI).
# Idempotent : `helm upgrade --install`. Relançable sans casse.
# À lancer depuis la racine du dépôt : ./_k8s/trivy-operator/trivy-operator-up.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"

# --- Versions épinglées (overridables par variable d'env) -------------------
TRIVY_OPERATOR_VERSION="${TRIVY_OPERATOR_VERSION:-0.34.0}"        # app v0.32.0
POLICY_REPORTER_VERSION="${POLICY_REPORTER_VERSION:-3.8.1}"

# --- Domaine : défaut versionné neutre, surchargeable par LAB_DOMAIN (lab.env ou env) ---
# `sed -n s///p` (jamais `grep` : sans match il renvoie 1 et tue le script sous `pipefail`).
# `|| true` : sans lab.env du tout, `sed` sort en 2 — ce qui tuerait aussi le script.
LAB_DOMAIN="${LAB_DOMAIN:-$(sed -n 's/^[[:space:]]*LAB_DOMAIN=//p' "${REPO_DIR}/lab.env" 2>/dev/null | head -n1 | tr -d " \"'" || true)}"
LAB_DOMAIN="${LAB_DOMAIN:-kubeadm.lab.example.io}"

for bin in kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable." >&2; exit 1; }
done
kubectl get --raw='/readyz' >/dev/null 2>&1 || { echo "ERREUR : apiserver injoignable (KUBECONFIG=${KUBECONFIG})." >&2; exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ============================================================================
log "[1/2] Trivy Operator ${TRIVY_OPERATOR_VERSION}"
helm repo add aqua https://aquasecurity.github.io/helm-charts/ >/dev/null 2>&1 || true
helm repo update aqua >/dev/null
helm upgrade --install trivy-operator aqua/trivy-operator -n trivy-system --create-namespace \
  --version "${TRIVY_OPERATOR_VERSION}" \
  --values _k8s/trivy-operator/values.yaml
kubectl -n trivy-system rollout status deploy/trivy-operator --timeout=180s

log "[2/2] Policy Reporter : activation du plugin trivy (UI unifiée)"
if helm -n kyverno status policy-reporter >/dev/null 2>&1; then
  helm repo add policy-reporter https://kyverno.github.io/policy-reporter >/dev/null 2>&1 || true
  helm repo update policy-reporter >/dev/null
  helm upgrade --install policy-reporter policy-reporter/policy-reporter -n kyverno \
    --version "${POLICY_REPORTER_VERSION}" \
    --values _k8s/kyverno/policy-reporter-values.yaml
  kubectl -n kyverno rollout status deploy/policy-reporter-trivy-plugin --timeout=180s || true
else
  echo "    /!\\ release policy-reporter absente du ns kyverno : installe d'abord ./_k8s/kyverno/kyverno-up.sh"
  echo "        Trivy Operator fonctionne quand même ; l'UI unifiée n'aura pas la source trivy."
fi

# ============================================================================
log "Trivy Operator installé."
echo "  Scanne en continu → les rapports arrivent au fil des scans (quelques minutes) :"
echo "    kubectl get vulnerabilityreports -A"
echo "    kubectl get configauditreports -A"
echo "    kubectl get exposedsecretreports -A"
echo "  UI unifiée (source Trivy) : https://kyverno.${LAB_DOMAIN}"
