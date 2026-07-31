#!/usr/bin/env bash
# Config côté serveur Vault pour le lab : auth Kubernetes + moteur KV-v2 "kubeadm-lab/"
# (un sous-dossier par appli) + policy/role de l'appli de démo "nginx-test-vault".
#
# Idempotent : relançable sans casse. À lancer depuis l'hôte avec le CLI vault :
#   export VAULT_ADDR=https://vault.kubeadm.lab.example.io
#   export VAULT_TOKEN=<root-token>
#   ./_k8s/vault-secret-operator/vault/kubeadm-lab.sh
#
# (Vault tourne IN-CLUSTER — chart vault-cluster/ — donc l'auth k8s se configure en mode
#  in-cluster : Vault valide les tokens de SA via son propre SA délégateur.)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${VAULT_ADDR:?export VAULT_ADDR (ex: https://vault.kubeadm.lab.example.io)}"
: "${VAULT_TOKEN:?export VAULT_TOKEN (root token, cf. vault-cluster/)}"

echo "==> 1. Auth Kubernetes"
vault auth enable kubernetes 2>/dev/null || echo "   (auth/kubernetes déjà activé)"
# Vault étant in-cluster, il joint l'API via l'adresse de service interne et utilise le
# token/CA montés dans son pod + son SA délégateur (chart vault : authDelegator activé).
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" >/dev/null
echo "   auth/kubernetes configuré (host=https://kubernetes.default.svc)"

echo "==> 2. Moteur KV-v2 kubeadm-lab/"
vault secrets enable -path=kubeadm-lab -version=2 kv 2>/dev/null \
  || echo "   (moteur kubeadm-lab/ déjà activé)"

echo "==> 3. Secrets de démo (un sous-dossier par appli)"
# Convention : kubeadm-lab/<appli>/<clé-logique>. Ici l'appli nginx-test-vault.
vault kv put kubeadm-lab/nginx-test-vault/config \
  APP_GREETING="Bonjour depuis Vault" \
  APP_COLOR="blue" \
  APP_SECRET_TOKEN="s3cr3t-v1" >/dev/null
echo "   kubeadm-lab/nginx-test-vault/config écrit"

echo "==> 4. Policy (lecture du sous-dossier nginx-test-vault uniquement)"
vault policy write kubeadm-lab-nginx-test-vault "$HERE/policies/kubeadm-lab-nginx-test-vault.hcl"

echo "==> 5. Role auth/kubernetes 'nginx-test-vault' -> SA nginx-test-vault / ns nginx-test-vault"
# bound_service_account_* = QUI peut se logger (identité exacte du pod applicatif).
# audience "vault" DOIT matcher VaultAuth.spec.kubernetes.audiences côté K8s.
vault write auth/kubernetes/role/nginx-test-vault \
  bound_service_account_names="nginx-test-vault" \
  bound_service_account_namespaces="nginx-test-vault" \
  audience="vault" \
  token_policies="kubeadm-lab-nginx-test-vault" \
  token_ttl="15m" >/dev/null

echo "==> OK. Vérifs :"
echo "   vault kv get kubeadm-lab/nginx-test-vault/config"
echo "   vault read auth/kubernetes/role/nginx-test-vault"
