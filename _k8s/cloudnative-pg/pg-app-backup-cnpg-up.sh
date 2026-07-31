#!/usr/bin/env bash
#
# pg-app-backup-cnpg-up.sh — met en place le backup NATIF CloudNativePG (CRD) vers MinIO S3
# pour le cluster `pg-demo` (contient la base `app`). Backup PHYSIQUE + archivage WAL (PITR).
#
# Étapes (idempotent) :
#   1. bucket MinIO `cnpg-backups` + utilisateur dédié `cnpg-backup` (scopé au bucket) ;
#   2. Secret K8s `cnpg-backup-s3` (access/secret key) dans cnpg-demo ;
#   3. patch du Cluster `pg-demo` avec `spec.backup.barmanObjectStore` (=> archivage WAL) ;
#   4. ScheduledBackup horaire + un Backup à la demande (pg-app-backup-cnpg.yaml).
#
# ⚠️ CNPG ≤ 1.30 : l'in-tree `barmanObjectStore` marche mais est DÉPRÉCIÉ (retrait prévu en
#    1.31). Migration future : Barman Cloud Plugin (CNPG-I). Voir README.
#
# Prérequis : addon minio-s3/cluster déployé + cluster pg-demo UP. À lancer depuis la racine du dépôt.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"
HERE="_k8s/cloudnative-pg"

for bin in kubectl curl openssl; do command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' manquant." >&2; exit 1; }; done
kubectl -n cnpg-demo get cluster pg-demo >/dev/null 2>&1 || { echo "ERREUR : cluster pg-demo absent." >&2; exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

MC="$(command -v mc || true)"
# `mc` est téléchargé pour la plateforme de l'HÔTE, pas pour Linux en dur : ce script
# tourne sur le poste (il fait un `kubectl port-forward` sur 127.0.0.1), et un binaire
# linux-amd64 sur un Mac Apple Silicon échoue en « exec format error ».
mc_url() {
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
  printf 'https://dl.min.io/client/mc/release/%s-%s/mc' "$os" "$arch"
}
if [ -z "$MC" ]; then MC="$(mktemp -d)/mc"; curl -fsSL -o "$MC" "$(mc_url)" && chmod +x "$MC"; fi

log "MinIO : bucket cnpg-backups + utilisateur dédié cnpg-backup"
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
"$MC" mb --ignore-existing _lab/cnpg-backups >/dev/null
POLICY="$(mktemp)"; cat > "$POLICY" <<'JSON'
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["s3:*"],"Resource":["arn:aws:s3:::cnpg-backups","arn:aws:s3:::cnpg-backups/*"]} ]}
JSON
"$MC" admin policy create _lab cnpg-backups-rw "$POLICY" >/dev/null 2>&1 || true
if kubectl -n cnpg-demo get secret cnpg-backup-s3 >/dev/null 2>&1; then
  SK="$(kubectl -n cnpg-demo get secret cnpg-backup-s3 -o jsonpath='{.data.SECRET_ACCESS_KEY}' | base64 -d)"
else
  SK="$(openssl rand -base64 21 | tr -d '/+=' | head -c 28)"
fi
"$MC" admin user add _lab cnpg-backup "$SK" >/dev/null 2>&1 || true
"$MC" admin policy attach _lab cnpg-backups-rw --user cnpg-backup >/dev/null 2>&1 || true
kill $PF 2>/dev/null || true; trap - EXIT

log "Secret K8s cnpg-backup-s3 (ns cnpg-demo)"
kubectl -n cnpg-demo create secret generic cnpg-backup-s3 \
  --from-literal=ACCESS_KEY_ID=cnpg-backup \
  --from-literal=SECRET_ACCESS_KEY="$SK" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "Patch du Cluster pg-demo : barmanObjectStore -> MinIO (active l'archivage WAL)"
kubectl -n cnpg-demo patch cluster pg-demo --type=merge -p '{
  "spec":{"backup":{"retentionPolicy":"7d","barmanObjectStore":{
    "destinationPath":"s3://cnpg-backups/",
    "endpointURL":"http://minio.minio-cluster.svc.cluster.local:9000",
    "s3Credentials":{"accessKeyId":{"name":"cnpg-backup-s3","key":"ACCESS_KEY_ID"},
                     "secretAccessKey":{"name":"cnpg-backup-s3","key":"SECRET_ACCESS_KEY"}},
    "wal":{"compression":"gzip"},"data":{"compression":"gzip"}}}}}'
echo "    attente ContinuousArchiving=True..."
for _ in $(seq 1 20); do
  [ "$(kubectl -n cnpg-demo get cluster pg-demo -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}' 2>/dev/null)" = "True" ] && break
  sleep 6
done

log "ScheduledBackup horaire + Backup à la demande"
kubectl apply -f "${HERE}/pg-app-backup-cnpg.yaml"

log "Prêt."
echo "  Suivi backups : kubectl -n cnpg-demo get backups"
echo "  Objets MinIO  : mc ls -r _lab/cnpg-backups/pg-demo/"
echo "  PITR possible : kubectl -n cnpg-demo get cluster pg-demo -o jsonpath='{.status.firstRecoverabilityPoint}'"
