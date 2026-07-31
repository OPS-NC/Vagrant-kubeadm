#!/usr/bin/env bash
#
# pg-backup-up.sh — met en place le backup HORAIRE de la base `vault` vers MinIO (S3),
# via les identifiants PostgreSQL GÉRÉS PAR VAULT (secret pg-rotate-creds).
#
# Ce que fait le script (idempotent) :
#   1. crée le bucket MinIO `pg-backups` + un utilisateur DÉDIÉ `pg-backup` scopé au bucket ;
#   2. crée le Secret K8s `minio-backup-creds` (endpoint + access/secret key) dans pg-rotate-demo ;
#   3. applique le CronJob `pg-backup-vault-s3` (pg-backup-vault-s3.yaml).
#
# ⚠️ Backup LOGIQUE (pg_dump) — n'utilise PAS les CRD de backup CloudNativePG (Barman) : le but
#    est justement de sauvegarder AVEC les creds Vault. Voir README pour l'alternative CNPG-native.
#
# Prérequis : addon minio-s3/cluster déployé, rotation Vault en place (pg-rotate-creds présent),
# cluster pg-demo UP. À lancer depuis la racine du dépôt.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"
HERE="_k8s/cloudnative-pg"

for bin in kubectl curl openssl; do command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' manquant." >&2; exit 1; }; done
kubectl -n pg-rotate-demo get secret pg-rotate-creds >/dev/null 2>&1 || { echo "ERREUR : secret pg-rotate-creds absent (rotation Vault pas en place ?)." >&2; exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# --- mc (client MinIO) : binaire statique local si absent -------------------
MC="$(command -v mc || true)"
# `mc` est téléchargé pour la plateforme de l'HÔTE, pas pour Linux en dur : ce script
# tourne sur le poste (il fait un `kubectl port-forward` sur 127.0.0.1), et un binaire
# linux-amd64 sur un Mac Apple Silicon échoue en « exec format error ».
mc_url() {
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
  printf 'https://dl.min.io/client/mc/release/%s-%s/mc' "$os" "$arch"
}
if [ -z "$MC" ]; then
  MC="$(mktemp -d)/mc"
  curl -fsSL -o "$MC" "$(mc_url)" && chmod +x "$MC"
fi

log "MinIO : bucket pg-backups + utilisateur dédié pg-backup"
ROOTPW="$(kubectl -n minio-cluster get secret minio-creds -o jsonpath='{.data.root-password}' | base64 -d)"
kubectl -n minio-cluster port-forward svc/minio 19000:9000 >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
# Attente BORNÉE : si le port-forward meurt (pod redémarré, svc absent), une boucle
# `until` infinie laissait le script tourner dans le vide sans jamais rien dire.
for _ in $(seq 1 60); do
  curl -s -o /dev/null http://127.0.0.1:19000/minio/health/ready 2>/dev/null && break
  kill -0 "$PF" 2>/dev/null || { echo "ERREUR : le port-forward vers svc/minio est mort." >&2; exit 1; }
  sleep 1
done
curl -sf -o /dev/null http://127.0.0.1:19000/minio/health/ready \
  || { echo "ERREUR : MinIO (minio-cluster) pas prêt après 60s — kubectl -n minio-cluster get pods" >&2; exit 1; }
"$MC" alias set _lab http://127.0.0.1:19000 admin "$ROOTPW" >/dev/null
"$MC" mb --ignore-existing _lab/pg-backups >/dev/null
POLICY="$(mktemp)"; cat > "$POLICY" <<'JSON'
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["s3:*"],"Resource":["arn:aws:s3:::pg-backups","arn:aws:s3:::pg-backups/*"]} ]}
JSON
"$MC" admin policy create _lab pg-backups-rw "$POLICY" >/dev/null 2>&1 || true

# Clé secrète du user : réutilise celle déjà dans le Secret K8s si présent (idempotence),
# sinon en génère une nouvelle et (re)crée le user avec.
if kubectl -n pg-rotate-demo get secret minio-backup-creds >/dev/null 2>&1; then
  SK="$(kubectl -n pg-rotate-demo get secret minio-backup-creds -o jsonpath='{.data.MINIO_SECRET_KEY}' | base64 -d)"
else
  SK="$(openssl rand -base64 21 | tr -d '/+=' | head -c 28)"
fi
"$MC" admin user add _lab pg-backup "$SK" >/dev/null 2>&1 || "$MC" admin user svcacct info _lab pg-backup >/dev/null 2>&1 || true
"$MC" admin policy attach _lab pg-backups-rw --user pg-backup >/dev/null 2>&1 || true
kill $PF 2>/dev/null || true; trap - EXIT

log "Secret K8s minio-backup-creds (ns pg-rotate-demo)"
kubectl -n pg-rotate-demo create secret generic minio-backup-creds \
  --from-literal=MINIO_ENDPOINT="http://minio.minio-cluster.svc.cluster.local:9000" \
  --from-literal=MINIO_ACCESS_KEY="pg-backup" \
  --from-literal=MINIO_SECRET_KEY="$SK" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "CronJob horaire pg-backup-vault-s3"
kubectl apply -f "${HERE}/pg-backup-vault-s3.yaml"

log "Prêt."
echo "  Déclencher un backup tout de suite :"
echo "    kubectl -n pg-rotate-demo create job pg-backup-now --from=cronjob/pg-backup-vault-s3"
echo "  Lister les backups dans le bucket :"
echo "    mc ls _lab/pg-backups/    (ou via la console MinIO)"
