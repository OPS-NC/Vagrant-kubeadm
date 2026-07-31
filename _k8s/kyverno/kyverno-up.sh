#!/usr/bin/env bash
#
# kyverno-up.sh — installe Kyverno (policy engine) + Policy Reporter (UI) sur un cluster
# kubeadm déjà doté de la plateforme (Cilium + Envoy Gateway + cert-manager, cf. platform-up.sh).
#
# Ordre :
#   1. Kyverno            contrôleurs (admission/background/cleanup/reports) via Helm
#   2. Policies           ClusterPolicy pédagogiques (validate Audit + mutate + generate)
#   3. Policy Reporter    agrégation des PolicyReport + UI web
#   4. HTTPRoute          expose l'UI sous kyverno.$LAB_DOMAIN (main-gateway)
#
# Idempotent : `helm upgrade --install` + `kubectl apply`. Relançable sans casse.
# À lancer depuis la racine du dépôt : ./_k8s/kyverno/kyverno-up.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"
HERE="_k8s/kyverno"

# --- Versions épinglées (overridables par variable d'env) -------------------
KYVERNO_VERSION="${KYVERNO_VERSION:-3.8.2}"            # app v1.18.2
POLICY_REPORTER_VERSION="${POLICY_REPORTER_VERSION:-3.8.1}"

# --- Domaine : défaut versionné neutre, surchargeable par LAB_DOMAIN (lab.env ou env) ---
# `sed -n s///p` (jamais `grep` : sans match il renvoie 1 et tue le script sous `pipefail`).
# `|| true` : sans lab.env du tout, `sed` sort en 2 — ce qui tuerait aussi le script.
LAB_DOMAIN="${LAB_DOMAIN:-$(sed -n 's/^[[:space:]]*LAB_DOMAIN=//p' "${REPO_DIR}/lab.env" 2>/dev/null | head -n1 | tr -d " \"'" || true)}"
LAB_DOMAIN="${LAB_DOMAIN:-kubeadm.lab.example.io}"

# --- Pré-requis -------------------------------------------------------------
for bin in kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable." >&2; exit 1; }
done
kubectl get --raw='/readyz' >/dev/null 2>&1 || { echo "ERREUR : apiserver injoignable (KUBECONFIG=${KUBECONFIG})." >&2; exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ============================================================================
log "[1/4] Kyverno ${KYVERNO_VERSION}"
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update kyverno >/dev/null
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace \
  --version "${KYVERNO_VERSION}" \
  --values "${HERE}/values.yaml"
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=180s

log "[2/4] Policies pédagogiques (validate Audit + mutate + generate)"
kubectl apply -f "${HERE}/policies/"
echo "    policies chargées :"
kubectl get clusterpolicy

log "[3/4] Policy Reporter ${POLICY_REPORTER_VERSION} + UI + plugin Kyverno"
helm repo add policy-reporter https://kyverno.github.io/policy-reporter >/dev/null 2>&1 || true
helm repo update policy-reporter >/dev/null
helm upgrade --install policy-reporter policy-reporter/policy-reporter -n kyverno \
  --version "${POLICY_REPORTER_VERSION}" \
  --values "${HERE}/policy-reporter-values.yaml"
kubectl -n kyverno rollout status deploy/policy-reporter-ui --timeout=180s

log "[4/4] HTTPRoute (kyverno.${LAB_DOMAIN})"
sed "s/kubeadm\.lab\.example\.io/${LAB_DOMAIN}/g" "${HERE}/httproute.yaml" | kubectl apply -f -

# ============================================================================
log "Kyverno installé."
echo "  Policies    : $(kubectl get clusterpolicy --no-headers 2>/dev/null | wc -l) ClusterPolicy (validate en Audit)"
echo "  Rapports    : kubectl get policyreport -A   /   kubectl get clusterpolicyreport"
echo "  UI          : https://kyverno.${LAB_DOMAIN}  (via main-gateway, cert wildcard)"
echo "  Test        : curl --resolve kyverno.${LAB_DOMAIN}:443:192.168.56.200 https://kyverno.${LAB_DOMAIN}/"
