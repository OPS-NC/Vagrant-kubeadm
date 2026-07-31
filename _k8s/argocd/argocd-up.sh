#!/usr/bin/env bash
#
# argocd-up.sh — installe Argo CD (GitOps) sur le cluster kubeadm et expose son UI/API en
# HTTPS sous argo.$LAB_DOMAIN via main-gateway (Envoy Gateway + cert wildcard).
#
# N'est PLUS installé par platform-up.sh : Argo CD est un addon à part (comme longhorn/,
# vault-cluster/, kyverno/…). platform-up.sh ne pose que Cilium + Envoy + metrics + cert-manager.
#
# Prérequis : plateforme en place (main-gateway HTTPS + cert wildcard cert-manager).
# Idempotent : `helm upgrade --install` + `kubectl apply`. Relançable sans casse.
# À lancer depuis la racine du dépôt : ./_k8s/argocd/argocd-up.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"

ARGOCD_VERSION="${ARGOCD_VERSION:-10.2.1}"

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
log "Argo CD ${ARGOCD_VERSION} + HTTPRoute (argo.${LAB_DOMAIN})"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
# values.yaml contient le domaine (global.domain + configs.cm.url) : rendu dans un temporaire.
VALUES="$(mktemp)"; trap 'rm -f "$VALUES"' EXIT
sed "s/kubeadm\.lab\.example\.io/${LAB_DOMAIN}/g" _k8s/argocd/values.yaml > "$VALUES"
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  --version "${ARGOCD_VERSION}" --values "$VALUES"
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
sed "s/kubeadm\.lab\.example\.io/${LAB_DOMAIN}/g" _k8s/argocd/httproute.yaml | kubectl apply -f -

# ============================================================================
log "Argo CD installé."
echo "  UI          : https://argo.${LAB_DOMAIN}   (user: admin)"
echo "  Mot de passe : kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo"
echo "  Test        : curl --resolve argo.${LAB_DOMAIN}:443:192.168.56.200 https://argo.${LAB_DOMAIN}/"
