#!/usr/bin/env bash
# Config côté Vault pour la ROTATION DE MOT DE PASSE PostgreSQL (moteur database, static role).
#
# Vault se connecte au cluster CloudNativePG `pg-demo` avec l'utilisateur ADMIN (postgres) et
# prend en gestion le mot de passe du user PG fixe `vault-rotate`, qu'il fait tourner
# périodiquement. Le VSO lit `database/static-creds/vault-rotate` -> Secret K8s -> app (voir
# ../k8s/pg-dynamic-rotate/pg-dynamic-rotate.yaml).
#
# STATIC ROLE (≠ dynamic role) : le username reste `vault-rotate`, SEUL le mot de passe change.
# La chaîne de connexion de l'app est donc stable, seul le password est rotaté.
#
# Prérequis :
#   - Cluster CloudNativePG `pg-demo` (ns cnpg-demo) avec enableSuperuserAccess=true
#     (kubectl -n cnpg-demo patch cluster pg-demo --type=merge -p '{"spec":{"enableSuperuserAccess":true}}')
#   - La base `vault` et le role `vault-rotate` (LOGIN) créés dans PG (cf. README).
#   - VAULT_ADDR + VAULT_TOKEN (root/admin) exportés ; KUBECONFIG pour lire le secret admin.
#     export VAULT_ADDR=http://127.0.0.1:8200      # port-forward svc/vault-active
#     export VAULT_TOKEN=<root-token>
#   ./_k8s/vault-secret-operator/vault/pg-dynamic-rotate.sh
set -euo pipefail
: "${VAULT_ADDR:?export VAULT_ADDR}"
: "${VAULT_TOKEN:?export VAULT_TOKEN (root/admin)}"
export KUBECONFIG="${KUBECONFIG:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/kubeconfig}"

# Réglable : fréquence de rotation. Chaque rotation relance le pod consommateur
# (rolloutRestartTargets). Baisser (ex. 2m) pour observer la boucle en direct.
ROTATION_PERIOD="${ROTATION_PERIOD:-3h}"

# --- Mot de passe admin (postgres) depuis le Secret CNPG -----------------------
SUPW="$(kubectl -n cnpg-demo get secret pg-demo-superuser -o jsonpath='{.data.password}' | base64 -d)"
[ -n "$SUPW" ] || { echo "ERREUR : secret pg-demo-superuser introuvable (enableSuperuserAccess=true ?)." >&2; exit 1; }

echo "==> 1. Moteur database/"
vault secrets enable database 2>/dev/null || echo "   (database/ déjà activé)"

echo "==> 2. Connexion admin -> CNPG (pg-demo-rw, user postgres)"
# {{username}}/{{password}} sont substitués par Vault (il pourra aussi rotater SON propre
# mot de passe admin via database/rotate-root/ si souhaité — non fait ici).
vault write database/config/pg-demo \
  plugin_name=postgresql-database-plugin \
  allowed_roles="vault-rotate" \
  connection_url="postgresql://{{username}}:{{password}}@pg-demo-rw.cnpg-demo.svc.cluster.local:5432/postgres?sslmode=require" \
  username="postgres" password="$SUPW" \
  password_authentication="scram-sha-256" >/dev/null
echo "   database/config/pg-demo écrit"

echo "==> 3. Static role vault-rotate (rotation_period=${ROTATION_PERIOD})"
# db_name = nom de la CONNEXION (pas de la base). username = user PG existant à gérer.
vault write database/static-roles/vault-rotate \
  db_name=pg-demo \
  username="vault-rotate" \
  rotation_period="${ROTATION_PERIOD}" >/dev/null
echo "   database/static-roles/vault-rotate écrit"

echo "==> 4. Policy (lecture du static-creds uniquement)"
echo 'path "database/static-creds/vault-rotate" { capabilities = ["read"] }' \
  | vault policy write pg-rotate-demo -

echo "==> 5. Role auth/kubernetes 'pg-rotate-demo' -> SA pg-rotate / ns pg-rotate-demo"
vault write auth/kubernetes/role/pg-rotate-demo \
  bound_service_account_names="pg-rotate" \
  bound_service_account_namespaces="pg-rotate-demo" \
  audience="vault" \
  token_policies="pg-rotate-demo" \
  token_ttl="15m" >/dev/null

echo "==> OK. Vérifs :"
echo "   vault read database/static-creds/vault-rotate     # username + password courant + ttl"
echo "   vault write -f database/rotate-role/vault-rotate  # forcer une rotation immédiate"
