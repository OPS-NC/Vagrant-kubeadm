#!/usr/bin/env bash
#
# node-problem-detector-up.sh — installe node-problem-detector (NPD), un DaemonSet qui
# surveille la SANTÉ DES NODES et remonte les problèmes en NodeConditions + Events.
#
# Namespace en PodSecurity `privileged` (NPD tourne en privileged pour lire /dev/kmsg) :
# kubeadm n'applique aucun niveau par défaut, l'étiquette rend l'intention explicite et
# tient si l'admission est durcie. Config réduite au kernel-monitor (kmsg) — cf. values.yaml.
#
# Idempotent : `helm upgrade --install`. À lancer depuis la racine du dépôt.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"
HERE="_k8s/node-problem-detector"
NPD_VERSION="${NPD_VERSION:-2.3.14}"        # app v0.8.19

for bin in kubectl helm; do command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable." >&2; exit 1; }; done
kubectl get --raw='/readyz' >/dev/null 2>&1 || { echo "ERREUR : apiserver injoignable." >&2; exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

log "Namespace node-problem-detector en PodSecurity 'privileged' (accès /dev/kmsg)"
kubectl create namespace node-problem-detector --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace node-problem-detector \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged --overwrite

log "node-problem-detector ${NPD_VERSION}"
helm repo add deliveryhero https://charts.deliveryhero.io/ >/dev/null 2>&1 || true
helm repo update deliveryhero >/dev/null
helm upgrade --install node-problem-detector deliveryhero/node-problem-detector \
  -n node-problem-detector --version "${NPD_VERSION}" \
  --values "${HERE}/values.yaml"
kubectl -n node-problem-detector rollout status daemonset/node-problem-detector --timeout=120s

log "Installé."
echo "  Pods (1/node) : kubectl -n node-problem-detector get pods -o wide"
echo "  Conditions    : kubectl get nodes -o json | jq -r '.items[].status.conditions[] | select(.type|test(\"KernelDeadlock|ReadonlyFilesystem\"))'"
echo "  Events node   : kubectl get events -A --field-selector reason=OOMKilling,reason=TaskHung"
