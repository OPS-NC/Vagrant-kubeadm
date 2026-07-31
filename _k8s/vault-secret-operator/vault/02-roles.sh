#!/usr/bin/env bash
# Charge les policies et crée les ROLES de la méthode auth/kubernetes.
# Un role = un contrat "quel SA, dans quel namespace, avec quelle policy, pour quelle audience".
# C'est ici qu'on applique le moindre privilège : on binde des SA/ns PRÉCIS (jamais "*").
#
# Prérequis : VAULT_ADDR + VAULT_TOKEN (admin). Lancer après 00 et 01.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Écriture des policies"
vault policy write vso-static-kv    "$HERE/policies/vso-static-kv.hcl"
vault policy write vso-dynamic-db   "$HERE/policies/vso-dynamic-db.hcl"
vault policy write vso-pki          "$HERE/policies/vso-pki.hcl"
vault policy write vso-transit      "$HERE/policies/vso-transit-cache.hcl"

# Paramètres communs des roles applicatifs.
#  - bound_service_account_names/namespaces : QUI peut se logger (identité exacte du pod).
#  - audience : DOIT matcher VaultAuth.spec.kubernetes.audiences côté K8s (ici "vault").
#  - token_ttl court : un token émis est de courte durée (moindre exposition).
APP_NS="demo"                 # namespace des apps (k8s/00-namespace-rbac.yaml)
APP_SA="vso-app"              # ServiceAccount des apps

echo "==> Role vso-static (KV-v2) -> SA $APP_SA / ns $APP_NS"
vault write auth/kubernetes/role/vso-static \
  bound_service_account_names="$APP_SA" \
  bound_service_account_namespaces="$APP_NS" \
  audience="vault" \
  token_policies="vso-static-kv" \
  token_ttl="15m"

echo "==> Role vso-dynamic (database)"
vault write auth/kubernetes/role/vso-dynamic \
  bound_service_account_names="$APP_SA" \
  bound_service_account_namespaces="$APP_NS" \
  audience="vault" \
  token_policies="vso-dynamic-db" \
  token_ttl="15m"

echo "==> Role vso-pki (certificats)"
vault write auth/kubernetes/role/vso-pki \
  bound_service_account_names="$APP_SA" \
  bound_service_account_namespaces="$APP_NS" \
  audience="vault" \
  token_policies="vso-pki" \
  token_ttl="15m"

# Role dédié à L'OPÉRATEUR pour chiffrer son cache client via Transit.
# Le SA de l'opérateur (chart VSO) : vault-secrets-operator-controller-manager.
echo "==> Role vso-transit (cache client de l'opérateur)"
vault write auth/kubernetes/role/vso-transit \
  bound_service_account_names="vault-secrets-operator-controller-manager" \
  bound_service_account_namespaces="vault-secrets-operator" \
  audience="vault" \
  token_policies="vso-transit" \
  token_ttl="15m"

echo "==> Roles créés. Vérifier : vault list auth/kubernetes/role"
