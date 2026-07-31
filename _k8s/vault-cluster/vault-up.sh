#!/usr/bin/env bash
#
# vault-up.sh — installe HashiCorp Vault en HA (Raft intégré, 3 réplicas) sur le cluster
# kubeadm, stockage Longhorn, et expose UI/API en HTTPS sous vault.$LAB_DOMAIN.
#
# Addon à part : platform-up.sh ne pose que Cilium + Envoy + metrics + le wildcard TLS.
#
# ⚠️ SECRETS. `vault operator init` produit 5 clés de descellement + le token root. Ce
# script les écrit dans `_out/vault-init.json` (répertoire gitignoré, fichier en 0600) et
# ne les affiche JAMAIS — ni sur stdout, ni dans un log. C'est le seul exemplaire : perdre
# ce fichier = Vault définitivement inaccessible. Le sortir de `_out/` = le sortir du
# gitignore, donc risque de commit.
#
# Descellement : le chart repart TOUJOURS scellé après un redémarrage de pod (upgrade,
# reboot du node, `vagrant halt`/`vagrant up`). Ce script redescelle ce qui doit l'être à chaque passage, tant
# que `_out/vault-init.json` est là. Pas d'auto-unseal dans ce lab (il
# faudrait un Transit externe ou un KMS cloud) : c'est donc à relancer après un reboot.
#
# Prérequis : Longhorn (SC `longhorn`), plateforme en place (main-gateway + wildcard), jq.
# Idempotent : n'initialise que si Vault ne l'est pas, ne descelle que les pods scellés.
# À lancer depuis la racine du dépôt : ./_k8s/vault-cluster/vault-up.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"

# --- Versions épinglées (overridables par variable d'env) -------------------
VAULT_CHART_VERSION="${VAULT_CHART_VERSION:-0.34.0}"
NS="${NS:-vault}"
REPLICAS=3                       # aligné sur values.yaml (server.ha.replicas)
INIT_FILE="${INIT_FILE:-${REPO_DIR}/_out/vault-init.json}"

# --- Lecture de lab.env -----------------------------------------------------
# `sed -n s///p` et JAMAIS `grep` : sans correspondance `grep` renvoie 1 et, sous
# `set -e` + `pipefail`, tuerait le script. `|| true` couvre l'absence de lab.env.
lire_lab_env() {
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" \
    "${REPO_DIR}/lab.env" 2>/dev/null | head -n1 | tr -d " \"'" || true
}
LAB_DOMAIN="${LAB_DOMAIN:-$(lire_lab_env LAB_DOMAIN)}"
LAB_DOMAIN="${LAB_DOMAIN:-kubeadm.lab.example.io}"

# --- Pré-requis -------------------------------------------------------------
for bin in kubectl helm jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable." >&2; exit 1; }
done
kubectl get --raw='/readyz' >/dev/null 2>&1 || { echo "ERREUR : apiserver injoignable (KUBECONFIG=${KUBECONFIG})." >&2; exit 1; }
# La StorageClass `longhorn` porte les 3 PVC Raft : sans elle les pods restent Pending.
kubectl get sc longhorn >/dev/null 2>&1 || {
  echo "ERREUR : StorageClass 'longhorn' absente — installe d'abord ../longhorn/longhorn-up.sh." >&2
  exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
# `vault status` sort en 2 quand Vault est scellé : `|| true` sinon `set -e` tue le script.
vault_status() { kubectl -n "$NS" exec "$1" -- vault status -format=json 2>/dev/null || true; }
# PIÈGE jq : l'opérateur `//` considère `false` comme vide, exactement comme `null`.
# `.sealed // true` renvoie donc `true` sur un pod DESCELLÉ (.sealed=false) — on croyait
# le pod scellé, et le `unseal` suivant échouait en 400 « already unsealed ». D'où
# `tostring`, qui distingue false de null. Renvoie "true" | "false" | "null".
champ_vault() { vault_status "$1" | jq -r ".$2 | tostring" 2>/dev/null || echo null; }
# Attente BORNÉE du `retry_join` Raft : vault-1/2 démarrent NON initialisés et ne le
# deviennent qu'après avoir rejoint le leader descellé. Les desceller avant ça échoue
# en 400 « Vault is not initialized » — c'est la course qui a cassé le premier passage.
attendre_initialise() {
  local pod="$1" limite="${2:-180}" t=0
  until [ "$(champ_vault "$pod" initialized)" = "true" ]; do
    t=$((t + 5)); [ "$t" -ge "$limite" ] && { echo "ERREUR : ${pod} n'a pas rejoint le Raft après ${limite}s." >&2
      echo "        Vérifier les retry_join : kubectl -n ${NS} logs ${pod} | tail -30" >&2; exit 1; }
    sleep 5
  done
}
# Attente BORNÉE d'un pod à l'état Running (les pods Vault ne deviennent JAMAIS Ready
# tant qu'ils sont scellés : attendre `condition=Ready` boucherait ici pour rien).
attendre_running() {
  local pod="$1" limite="${2:-180}" t=0
  until [ "$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ]; do
    t=$((t + 5)); [ "$t" -ge "$limite" ] && { echo "ERREUR : ${pod} pas Running après ${limite}s." >&2; \
      kubectl -n "$NS" get pod "$pod" >&2 || true; exit 1; }
    sleep 5
  done
}

# ============================================================================
log "[1/4] Chart Vault ${VAULT_CHART_VERSION} (HA Raft ${REPLICAS} réplicas, SC longhorn)"
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo update hashicorp >/dev/null
# PAS de --wait : les pods restent `0/1 Running` (readiness en échec) tant que Vault
# n'est ni initialisé ni descellé — `--wait` expirerait systématiquement.
helm upgrade --install vault hashicorp/vault \
  --namespace "$NS" --create-namespace \
  --version "${VAULT_CHART_VERSION}" \
  --values _k8s/vault-cluster/values.yaml
attendre_running vault-0 300

# ============================================================================
log "[2/4] Initialisation (5 clés, seuil 3)"
if [ "$(champ_vault vault-0 initialized)" = "true" ]; then
  echo "    Vault est déjà initialisé — on ne touche à rien."
  [ -f "$INIT_FILE" ] || echo "    /!\\ ${INIT_FILE} absent : le descellement ci-dessous sera à faire à la main."
else
  [ -f "$INIT_FILE" ] && { echo "ERREUR : Vault n'est pas initialisé mais ${INIT_FILE} existe déjà." >&2
    echo "        Écraser ce fichier perdrait les clés qu'il contient. Déplace-le puis relance." >&2
    exit 1; }
  mkdir -p "$(dirname "$INIT_FILE")"
  # umask AVANT la redirection : le fichier naît en 0600, jamais lisible en 0644 même
  # une fraction de seconde. Les clés ne transitent pas par stdout.
  ( umask 077 && kubectl -n "$NS" exec vault-0 -- \
      vault operator init -key-shares=5 -key-threshold=3 -format=json > "$INIT_FILE" )
  echo "    Clés + token root écrits dans ${INIT_FILE} (0600, _out/ est gitignoré)."
  echo "    C'est le SEUL exemplaire : sauvegarde-le hors du dépôt."
fi

# ============================================================================
log "[3/4] Descellement des ${REPLICAS} pods"
if [ -f "$INIT_FILE" ]; then
  for n in $(seq 0 $((REPLICAS - 1))); do
    pod="vault-${n}"
    # vault-1/2 n'existent qu'après que le StatefulSet ait déroulé : on les attend,
    # puis on attend qu'ils aient rejoint le Raft (sinon 400 « not initialized »).
    attendre_running "$pod" 300
    attendre_initialise "$pod" 300
    if [ "$(champ_vault "$pod" sealed)" = "false" ]; then
      echo "    ${pod} : déjà descellé"
      continue
    fi
    # 3 clés distinctes = le seuil. `>/dev/null` : la sortie de `unseal` réaffiche
    # l'état du seau, pas la clé — mais on ne prend aucun risque avec ce flux.
    for i in 0 1 2; do
      kubectl -n "$NS" exec "$pod" -- vault operator unseal \
        "$(jq -r ".unseal_keys_b64[$i]" "$INIT_FILE")" >/dev/null
    done
    echo "    ${pod} : descellé"
  done
  kubectl -n "$NS" wait --for=condition=Ready pod -l app.kubernetes.io/name=vault --timeout=180s
else
  echo "    ${INIT_FILE} absent : descellement manuel requis (3 clés sur 5) —"
  echo "      kubectl -n ${NS} exec vault-0 -- vault operator unseal <clé>"
fi

# ============================================================================
log "[4/4] HTTPRoute vault.${LAB_DOMAIN}"
# Le manifeste versionné porte le domaine neutre : substitué à la volée, comme
# partout ailleurs dans _k8s/ (cf. ../README.md).
sed "s/kubeadm\.lab\.example\.io/${LAB_DOMAIN}/g" _k8s/vault-cluster/httproute.yaml | kubectl apply -f -

# ============================================================================
log "Vault installé."
echo "  UI/API   : https://vault.${LAB_DOMAIN}"
echo "  Stockage : Raft intégré, 3 PVC de 2Gi sur la SC longhorn"
echo "  Token root (NE PAS le coller ailleurs) :"
echo "    jq -r .root_token ${INIT_FILE}"
echo "  Depuis l'hôte :"
echo "    export VAULT_ADDR=https://vault.${LAB_DOMAIN}"
echo "    export VAULT_TOKEN=\$(jq -r .root_token ${INIT_FILE})"
echo
echo "  /!\\ Pas d'auto-unseal : après un reboot ou un upgrade, les pods repartent SCELLÉS."
echo "      Relancer ce script les redescelle (tant que ${INIT_FILE} existe)."
