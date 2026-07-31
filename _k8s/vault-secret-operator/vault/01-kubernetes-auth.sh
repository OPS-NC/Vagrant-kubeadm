#!/usr/bin/env bash
# Active et configure la méthode d'auth Kubernetes de Vault (auth/kubernetes).
# C'est ce qui permet à VSO de prouver son identité à Vault via le token d'un ServiceAccount,
# validé par l'API TokenReview du cluster.
#
# DEUX MODES selon où tourne Vault :
#   A) Vault IN-CLUSTER  : Vault utilise son propre SA (délégateur) comme reviewer. Config minimale.
#   B) Vault EXTERNE     : il faut fournir kubernetes_host + kubernetes_ca_cert + token_reviewer_jwt.
#
# Prérequis : VAULT_ADDR + VAULT_TOKEN (admin) exportés. Choisir le mode via MODE=incluster|external.
set -euo pipefail

MODE="${MODE:-incluster}"
KUBE_HOST="${KUBE_HOST:-https://192.168.56.5:6443}"   # VIP API du lab (portée par keepalived, cf. kubeadm/provision.sh)

vault auth enable kubernetes 2>/dev/null || echo "  (auth/kubernetes déjà activé)"

case "$MODE" in
  incluster)
    # Vault tourne dans le cluster. Son ServiceAccount doit avoir system:auth-delegator
    # (le chart hashicorp/vault le fait via server.authDelegator.enabled=true, activé par défaut).
    # Sans token_reviewer_jwt/host/ca_cert, Vault utilise le token de SON pod + le CA/host montés
    # dans le conteneur (`disable_local_ca_jwt` reste à false, son défaut : c'est justement ce
    # qui autorise Vault à lire /var/run/secrets/kubernetes.io/serviceaccount/ dans son conteneur).
    #
    # On ne pose PAS `issuer=` : depuis Vault >= 1.9, `disable_iss_validation` vaut true par
    # défaut, la revendication `iss` du token n'est donc pas comparée. C'est la seule config
    # saine ici, car kubeadm émet les tokens de SA avec l'issuer
    # `https://kubernetes.default.svc.cluster.local` (défaut de `--service-account-issuer`,
    # non surchargé par kubeadm/templates/kubeadm-init.yaml.tpl) alors que `kubernetes_host`
    # vaut `https://kubernetes.default.svc` : figer `issuer=` sur l'un ou l'autre casserait
    # le login dès que le défaut amont bougerait.
    echo "==> [mode in-cluster] config auth/kubernetes (Vault utilise son propre SA délégateur)"
    # ATTENTION : ce script tourne depuis l'HÔTE (CLI vault), pas dans un pod.
    # La forme "https://\$KUBERNETES_PORT_443_TCP_ADDR:443" vient de la doc HashiCorp
    # où elle est exécutée DANS un `kubectl exec … sh -c` : c'est le shell du pod qui
    # interpole la variable. Ici, Vault recevait et stockait la chaîne LITTÉRALE
    # (`$KUBERNETES_PORT_443_TCP_ADDR` non résolu) => tout login via auth/kubernetes
    # échouait en résolution DNS. On utilise donc le nom de service stable, résolu
    # par le pod Vault lui-même (idem vault/kubeadm-lab.sh).
    vault write auth/kubernetes/config \
      kubernetes_host="https://kubernetes.default.svc"
    ;;
  external)
    # Vault hors du cluster : il ne peut pas déduire host/CA/reviewer tout seul.
    # 1) Créer côté K8s un SA délégateur "vault-auth" + son token long (voir doc ci-dessous).
    # 2) Renseigner ici son JWT (SA_JWT), le CA de l'API K8s (SA_CA_CRT) et l'endpoint.
    : "${SA_JWT:?exporte SA_JWT = token du SA délégateur vault-auth}"
    : "${SA_CA_CRT:?exporte SA_CA_CRT = CA de l'API Kubernetes (PEM)}"
    echo "==> [mode externe] config auth/kubernetes (reviewer JWT explicite)"
    vault write auth/kubernetes/config \
      kubernetes_host="$KUBE_HOST" \
      kubernetes_ca_cert="$SA_CA_CRT" \
      token_reviewer_jwt="$SA_JWT"
    # Côté K8s, préparer le reviewer (à lancer avec kubectl AVANT ce script) :
    #   kubectl create sa vault-auth -n vault-secrets-operator
    #   kubectl create clusterrolebinding vault-auth-delegator \
    #     --clusterrole=system:auth-delegator \
    #     --serviceaccount=vault-secrets-operator:vault-auth
    #   SA_CA_CRT="$(kubectl get cm kube-root-ca.crt -n vault-secrets-operator -o jsonpath='{.data.ca\.crt}')"
    #   SA_JWT="$(kubectl create token vault-auth -n vault-secrets-operator --duration=8760h)"
    # ⚠️ Ne PAS forcer `--audience` ici : kubeadm laisse `--api-audiences` au défaut, c'est-à-dire
    #    la seule valeur `https://kubernetes.default.svc.cluster.local` (l'issuer). Un token
    #    demandé avec une autre audience est rejeté à l'authentification et le TokenReview de
    #    Vault échouerait alors en 401. Sans `--audience`, kubectl émet le token sur l'audience
    #    par défaut de l'apiserver : c'est ce qu'il faut.
    ;;
  *) echo "MODE inconnu: $MODE (incluster|external)"; exit 1 ;;
esac

# Le host effectif dépend du mode : en in-cluster, KUBE_HOST n'est pas utilisé
# (l'ancien résumé l'affichait quand même, ce qui laissait croire au contraire).
case "$MODE" in
  incluster) echo "==> auth/kubernetes configuré (mode=incluster, host=https://kubernetes.default.svc)." ;;
  external)  echo "==> auth/kubernetes configuré (mode=external, host=$KUBE_HOST)." ;;
esac

# Vérification : le host réellement enregistré côté Vault.
vault read -field=kubernetes_host auth/kubernetes/config \
  | sed 's/^/    host enregistré : /'
