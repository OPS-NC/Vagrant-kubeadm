#!/usr/bin/env bash
# Active les moteurs de secrets consommés par les CRD VSO : KV-v2 (static),
# database (dynamic), pki (certificats), transit (chiffrement du cache client).
# Idempotent : ré-exécutable sans casse (les "already in use" sont ignorées).
#
# Prérequis : VAULT_ADDR + VAULT_TOKEN (token admin) exportés, ou lancer dans un pod Vault.
#   export VAULT_ADDR=https://vault.kubeadm.lab.example.io      # ou http://127.0.0.1:8200 en port-forward
#   export VAULT_TOKEN=<root-ou-admin>
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# --- Domaine : défaut versionné neutre, surchargeable par LAB_DOMAIN (lab.env ou env) ---
# Sert de `common_name` à la CA racine PKI et d'`allowed_domains` au role `demo`.
# `sed -n s///p` (jamais `grep` : sans match il renvoie 1 et tue le script sous `pipefail`).
# `|| true` : sans lab.env du tout, `sed` sort en 2 — ce qui tuerait aussi le script.
LAB_DOMAIN="${LAB_DOMAIN:-$(sed -n 's/^[[:space:]]*LAB_DOMAIN=//p' "${REPO_DIR}/lab.env" 2>/dev/null | head -n1 | tr -d " \"'" || true)}"
LAB_DOMAIN="${LAB_DOMAIN:-kubeadm.lab.example.io}"

enable() { vault secrets enable "$@" 2>/dev/null || echo "  (déjà activé : $*)"; }

echo "==> [KV-v2] kvv2/ (secrets statiques)"
enable -path=kvv2 -version=2 kv
# Exemple de secret que lira le VaultStaticSecret (k8s/10-static-kv.yaml) :
vault kv put kvv2/demo/app username="app" password="s3cr3t-de-demo"

echo "==> [database] db/ (creds éphémères)"
enable database
# NB : la connexion + le role dépendent de TA base. Exemple PostgreSQL (à adapter) :
#   vault write db/config/demo-postgres \
#     plugin_name=postgresql-database-plugin \
#     allowed_roles="demo-app" \
#     connection_url="postgresql://{{username}}:{{password}}@postgres.demo.svc:5432/app?sslmode=disable" \
#     username="vault_admin" password="<pwd_admin_pg>"
#   vault write db/roles/demo-app \
#     db_name=demo-postgres \
#     creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
#     default_ttl=1h max_ttl=24h

echo "==> [pki] pki/ (certificats TLS)"
enable -path=pki pki
vault secrets tune -max-lease-ttl=87600h pki
# CA racine de démo (en prod : CA intermédiaire signée par une racine hors-ligne).
vault write -field=certificate pki/root/generate/internal \
  common_name="${LAB_DOMAIN}" ttl=87600h >/dev/null || echo "  (CA racine déjà générée)"
vault write pki/config/urls \
  issuing_certificates="${VAULT_ADDR}/v1/pki/ca" \
  crl_distribution_points="${VAULT_ADDR}/v1/pki/crl"
# Role PKI "demo" : borne les domaines et la durée. Le VaultPKISecret émet via ce role.
vault write pki/roles/demo \
  allowed_domains="${LAB_DOMAIN}" allow_subdomains=true \
  max_ttl=72h key_type=rsa key_bits=2048

echo "==> [transit] transit/ (chiffrement du cache client VSO)"
enable transit
vault write -f transit/keys/vso-client-cache >/dev/null || echo "  (clé transit déjà créée)"

echo "==> Moteurs prêts."
