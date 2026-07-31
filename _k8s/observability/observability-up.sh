#!/usr/bin/env bash
#
# observability-up.sh — installe la pile d'observabilité du lab kubeadm :
#   métriques (kube-prometheus-stack : Prometheus + Grafana + Alertmanager)
#   + logs (Loki single-binary + Grafana Alloy comme collecteur).
#
# Ordre :
#   1. kube-prometheus-stack   Prometheus (+ CRDs), Grafana, Alertmanager, exporters
#   2. Loki                    stockage de logs (single binary, filesystem sur Longhorn)
#   3. Alloy                   collecte les logs des pods → Loki
#   4. HTTPRoutes              grafana / prometheus / alertmanager .$LAB_DOMAIN
#
# Prérequis : plateforme en place (Cilium + Envoy Gateway + cert-manager), Longhorn +
# StorageClass `longhorn-r1` (posée par l'addon longhorn/).
# Idempotent : `helm upgrade --install` + `kubectl apply`. Relançable sans casse.
# À lancer depuis la racine du dépôt : ./_k8s/observability/observability-up.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"
HERE="_k8s/observability"

# --- Versions épinglées (overridables par variable d'env) -------------------
KPS_VERSION="${KPS_VERSION:-87.19.0}"          # kube-prometheus-stack (app Prometheus Operator v0.92.1)
LOKI_VERSION="${LOKI_VERSION:-7.1.0}"          # app Loki v3.6.8
ALLOY_VERSION="${ALLOY_VERSION:-1.11.0}"       # app Alloy v1.18.0

# --- Domaine : défaut versionné neutre, surchargeable par LAB_DOMAIN (lab.env ou env) ---
# `sed -n s///p` (jamais `grep` : sans match il renvoie 1 et tue le script sous `pipefail`).
# `|| true` : sans lab.env du tout, `sed` sort en 2 — ce qui tuerait aussi le script.
LAB_DOMAIN="${LAB_DOMAIN:-$(sed -n 's/^[[:space:]]*LAB_DOMAIN=//p' "${REPO_DIR}/lab.env" 2>/dev/null | head -n1 | tr -d " \"'" || true)}"
LAB_DOMAIN="${LAB_DOMAIN:-kubeadm.lab.example.io}"

for bin in kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable." >&2; exit 1; }
done
kubectl get --raw='/readyz' >/dev/null 2>&1 || { echo "ERREUR : apiserver injoignable (KUBECONFIG=${KUBECONFIG})." >&2; exit 1; }
kubectl get storageclass longhorn-r1 >/dev/null 2>&1 || { echo "ERREUR : StorageClass 'longhorn-r1' absente. Installe Longhorn puis applique le socle : kubectl apply -f _k8s/longhorn/longhorn-r1-storageclass.yaml" >&2; exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ============================================================================
log "[0/4] Namespace monitoring (PodSecurity privileged pour node-exporter + Alloy)"
kubectl apply -f "${HERE}/namespace.yaml"

log "[1/4] kube-prometheus-stack ${KPS_VERSION} (Prometheus + Grafana + Alertmanager)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
# Les values portent le domaine (Grafana domain/root_url, externalUrl) : rendu temporaire.
KPS_VALUES="$(mktemp)"; trap 'rm -f "$KPS_VALUES"' EXIT
sed "s/kubeadm\.lab\.example\.io/${LAB_DOMAIN}/g" "${HERE}/kube-prometheus-stack-values.yaml" > "$KPS_VALUES"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --version "${KPS_VERSION}" \
  --values "$KPS_VALUES"
kubectl -n monitoring rollout status deploy/kube-prometheus-stack-grafana --timeout=300s

log "[2/4] Loki ${LOKI_VERSION} (single binary, filesystem sur Longhorn)"
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update grafana >/dev/null
helm upgrade --install loki grafana/loki -n monitoring \
  --version "${LOKI_VERSION}" \
  --values "${HERE}/loki-values.yaml"
kubectl -n monitoring rollout status statefulset/loki --timeout=300s || true

log "[3/4] Grafana Alloy ${ALLOY_VERSION} (collecte des logs /var/log/pods → Loki)"
helm upgrade --install alloy grafana/alloy -n monitoring \
  --version "${ALLOY_VERSION}" \
  --values "${HERE}/alloy-values.yaml"
kubectl -n monitoring rollout status daemonset/alloy --timeout=180s || true

log "[4/4] HTTPRoutes (grafana / prometheus / alertmanager .${LAB_DOMAIN})"
sed "s/kubeadm\.lab\.example\.io/${LAB_DOMAIN}/g" "${HERE}/httproutes.yaml" | kubectl apply -f -

# ============================================================================
log "Observabilité installée."
echo "  Grafana      : https://grafana.${LAB_DOMAIN}  (admin / prom-operator — À CHANGER)"
echo "  Prometheus   : https://prometheus.${LAB_DOMAIN}"
echo "  Alertmanager : https://alertmanager.${LAB_DOMAIN}"
echo "  Datasources  : Prometheus (auto) + Loki (http://loki-gateway) → onglet Explore pour les logs"
echo "  Test         : curl --resolve grafana.${LAB_DOMAIN}:443:192.168.56.200 https://grafana.${LAB_DOMAIN}/api/health"
