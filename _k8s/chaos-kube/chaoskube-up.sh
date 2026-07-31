#!/usr/bin/env bash
#
# chaoskube-up.sh — installe chaoskube (chaos engineering) sur le cluster kubeadm.
# Tue UN pod au hasard toutes les heures, partout SAUF kube-system et longhorn-system.
#
# Addon à part : platform-up.sh ne pose que Cilium + Envoy + metrics + le wildcard TLS.
# Pas d'UI, donc pas d'HTTPRoute : chaoskube ne s'observe que dans ses logs (et les
# Events qu'il crée sur les pods supprimés).
#
# ⚠️ CET ADDON SUPPRIME DES PODS EN CONTINU. C'est son métier, mais ça se paie :
#   - tout ce qui n'est pas piloté par un contrôleur (pod nu) ne revient JAMAIS ;
#   - Vault repart SCELLÉ à chaque pod tué (pas d'auto-unseal dans ce lab) — il faut
#     relancer ../vault-cluster/vault-up.sh pour le redesceller.
# Pour arrêter les frais sans désinstaller : voir la fin de ce script.
#
# Prérequis : cluster Ready, kubectl + helm. Aucun stockage, aucun Gateway.
# Idempotent : `helm upgrade --install`, relançable sans casse.
# À lancer depuis la racine du dépôt : ./_k8s/chaos-kube/chaoskube-up.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"

# --- Versions épinglées (overridables par variable d'env) -------------------
CHAOSKUBE_VERSION="${CHAOSKUBE_VERSION:-0.6.0}"
NS="${NS:-chaos-kube}"
# CHAOS_DRY_RUN=1 : installe chaoskube en mode observation (il logue « would kill … »
# et ne supprime rien). Utile pour vérifier ce qu'il VISERAIT avant de lâcher les chiens.
CHAOS_DRY_RUN="${CHAOS_DRY_RUN:-0}"

# --- Pré-requis -------------------------------------------------------------
for bin in kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable." >&2; exit 1; }
done
kubectl get --raw='/readyz' >/dev/null 2>&1 || { echo "ERREUR : apiserver injoignable (KUBECONFIG=${KUBECONFIG})." >&2; exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ============================================================================
log "chaoskube ${CHAOSKUBE_VERSION} (namespace ${NS})"
helm repo add chaoskube https://linki.github.io/chaoskube/ >/dev/null 2>&1 || true
helm repo update chaoskube >/dev/null

# Repasser en dry-run demande de RETIRER la clé `no-dry-run`, pas de la mettre à false :
# le template du chart fait `range $key, $value` et émet `--$key` dès que la valeur est
# vide OU nulle. Donc `--set …no-dry-run=null` laisse le flag en place (vérifié au
# `helm template`), et `--no-dry-run=false` n'existe pas côté chaoskube. On rend donc les
# values dans un temporaire, la ligne en moins.
VALUES="$(mktemp)"; trap 'rm -f "$VALUES"' EXIT
if [ "$CHAOS_DRY_RUN" = "1" ]; then
  sed '/^ *no-dry-run:/d' _k8s/chaos-kube/values.yaml > "$VALUES"
  echo "    CHAOS_DRY_RUN=1 : mode observation, aucun pod ne sera supprimé."
else
  cat _k8s/chaos-kube/values.yaml > "$VALUES"
fi

helm upgrade --install chaoskube chaoskube/chaoskube \
  --namespace "$NS" --create-namespace \
  --version "${CHAOSKUBE_VERSION}" \
  --values "$VALUES" \
  --wait --timeout 5m
kubectl -n "$NS" rollout status deploy/chaoskube --timeout=180s

# ============================================================================
# On relit les flags REELLEMENT en place plutôt que de réafficher values.yaml : c'est la
# seule preuve que l'exclusion et le no-dry-run ont bien atterri dans le pod. Tout ce qui
# suit dérive de CES flags — un résumé codé en dur mentirait dès qu'on édite values.yaml.
args_actifs="$(kubectl -n "$NS" get deploy chaoskube \
  -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}')"
exclusions="$(printf '%s\n' "$args_actifs" | sed -n 's/^--namespaces=//p')"
intervalle="$(printf '%s\n' "$args_actifs" | sed -n 's/^--interval=//p')"

log "Flags actifs (lus depuis le Deployment)"
printf '    %s\n' $args_actifs

# ============================================================================
log "chaoskube installé."
echo "  Cible        : tous les namespaces, filtre '${exclusions}'"
echo "  Cadence      : 1 pod supprimé toutes les ${intervalle:-?}"
echo "  Logs         : kubectl -n ${NS} logs -f deploy/chaoskube"
echo "  Victimes     : kubectl get events -A --field-selector reason=Killing --sort-by=.lastTimestamp"
echo
echo "  Mettre en pause (sans désinstaller) :"
echo "    kubectl -n ${NS} scale deploy/chaoskube --replicas=0"
echo "  Repasser en observation seule :"
echo "    CHAOS_DRY_RUN=1 ./_k8s/chaos-kube/chaoskube-up.sh"
echo "  Désinstaller :"
echo "    helm -n ${NS} uninstall chaoskube"
echo
# Garde-fou, sur la même source que le résumé ci-dessus : on prévient si un namespace fragile
# du lab existe dans le cluster sans être exclu.
# vault : revient scellé. cnpg-demo : Postgres de démo. Les deux sont exclus par défaut.
for fragile in vault cnpg-demo; do
  kubectl get ns "$fragile" >/dev/null 2>&1 || continue
  case ",${exclusions}," in
    *",!${fragile},"*) continue ;;
  esac
  echo "  /!\\ Le namespace '${fragile}' existe et n'est PAS exclu (${exclusions})."
  [ "$fragile" = "vault" ] && \
    echo "      Chaque pod Vault tué repart SCELLÉ : ./_k8s/vault-cluster/vault-up.sh pour redesceller."
  echo "      Pour l'épargner : ajoute ',!${fragile}' à chaoskube.args.namespaces dans"
  echo "      _k8s/chaos-kube/values.yaml puis relance ce script."
done
