#!/usr/bin/env bash
#
# platform-up.sh — installe la couche « plateforme » du lab sur un cluster kubeadm
# déjà bootstrapé (après ./kubeadm/cluster-up.sh).
#
# ⚠️ `kubeadm init` n'installe AUCUN réseau pod : les nodes sont NotReady tant que
#    l'étape [1/4] n'est pas passée. C'est ce script qui pose le CNI, pas le bootstrap.
#
# Ordre (chaque maillon suppose le précédent) :
#   1. CNI                 selon `CNI` (cluster.env, puis lab.env) — cilium (défaut,
#                          + pool L2 => IP LB), calico (CNI seul), flannel (CNI seul), none
#   2. Envoy Gateway       contrôleur + CRD Gateway API + main-gateway (HTTP/HTTPS)
#   3. metrics-server      metrics.k8s.io (kubectl top)
#   4. wildcard TLS        selon `SELF_SIGNED` de lab.env :
#                          true  -> AC locale + cert openssl (self-signed/), PAS de cert-manager
#                          false -> cert-manager + secret Cloudflare + ClusterIssuers (ACME)
#                          Les deux chemins remplissent le MÊME Secret que sert la Gateway.
#
# EXCLUS volontairement (à installer à part, chacun son README + up.sh) :
#   argocd/ · longhorn/ · vault-cluster/ · vault-secret-operator/ · kyverno/ ·
#   trivy-operator/ · cloudnative-pg/
#
# Domaine : les manifestes versionnés portent le domaine NEUTRE `kubeadm.lab.example.io`
# (dépôt public). Il est remplacé à la volée par `LAB_DOMAIN` (env ou lab.env) — idem
# `LAB_DNS_ZONE` (zone du solveur DNS-01), `LAB_ACME_EMAIL` (compte Let's Encrypt) et
# `LAB_ACME_ISSUER` (staging par défaut / prod sur demande). Ces trois dernières ne
# servent QUE sur le chemin ACME (SELF_SIGNED=false).
#
# Idempotent : `helm upgrade --install` + `kubectl apply`. Relançable sans casse.
# À lancer depuis la racine du dépôt : ./_k8s/platform-up.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"

# --- Versions épinglées (overridables par variable d'env) -------------------
ENVOY_GW_VERSION="${ENVOY_GW_VERSION:-1.8.3}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.20.2}"

# --- Lecture des paramètres du lab ------------------------------------------
# `sed -n s///p` et JAMAIS `grep` : un `grep` sans correspondance renvoie 1 et, sous
# `set -e` + `pipefail`, tuait le script ici — silencieusement, avant même le CNI, dès
# que lab.env n'avait pas la clé. Le `|| true` couvre le cas « pas de fichier du tout »,
# où `sed` sort en 2. Le `tr` retire d'éventuels guillemets autour de la valeur.
lire_lab_env() {
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" \
    "${REPO_DIR}/lab.env" 2>/dev/null | head -n1 | tr -d " \"'" || true
}
# `_out/cluster.env` est écrit par kubeadm/cluster-up.sh : il porte des valeurs DÉTECTÉES
# sur le cluster réel (nom d'interface, CIDR effectif) là où lab.env n'exprime qu'une
# intention. On le lit donc en premier.
lire_cluster_env() {
  sed -n "s/^[[:space:]]*$1=//p" \
    "${REPO_DIR}/_out/cluster.env" 2>/dev/null | head -n1 | tr -d " \"'" || true
}
# Ordre de priorité : environnement > _out/cluster.env > lab.env > défaut.
lire_param() {  # lire_param NOM DEFAUT
  local v="${!1:-}"
  [ -z "$v" ] && v="$(lire_cluster_env "$1")"
  [ -z "$v" ] && v="$(lire_lab_env "$1")"
  printf '%s' "${v:-$2}"
}

# Garde-fou : sans cette fiche de faits, on retombe sur des valeurs DEVINÉES. Mieux vaut
# le dire ici que laisser Cilium s'épingler sur la mauvaise carte réseau trois étapes
# plus loin. Non bloquant : un cluster monté à la main reste utilisable via lab.env.
if [ ! -f "${REPO_DIR}/_out/cluster.env" ]; then
  echo "/!\\ _out/cluster.env absent : ./kubeadm/cluster-up.sh n'a pas (ou pas jusqu'au bout)" >&2
  echo "    été lancé sur ce dépôt. On continue avec lab.env et les défauts, mais l'interface" >&2
  echo "    host-only, le CIDR pod et le choix kube-proxy ne sont alors PAS vérifiés." >&2
fi

CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-$(lire_lab_env CLOUDFLARE_API_TOKEN)}"

# --- Domaine du lab : défaut versionné NEUTRE (le dépôt est public) ----------
# Les manifestes portent `kubeadm.lab.example.io` ; on le remplace à la volée par LAB_DOMAIN.
LAB_DOMAIN="${LAB_DOMAIN:-$(lire_lab_env LAB_DOMAIN)}"
LAB_DOMAIN="${LAB_DOMAIN:-kubeadm.lab.example.io}"
# Nom du Certificate/Secret wildcard : dérivé du domaine (points -> tirets), donc
# `wildcard-kubeadm-lab-example-io-tls` par défaut, `wildcard-<ton-domaine>-tls` sinon.
LAB_DOMAIN_DASH="${LAB_DOMAIN//./-}"
WILDCARD_TLS="wildcard-${LAB_DOMAIN_DASH}-tls"
# Zone DNS Cloudflare hébergeant LAB_DOMAIN (selector `dnsZones` du ClusterIssuer) :
# par défaut les deux derniers labels (kubeadm.lab.example.io -> example.io).
LAB_DNS_ZONE="${LAB_DNS_ZONE:-$(lire_lab_env LAB_DNS_ZONE)}"
LAB_DNS_ZONE="${LAB_DNS_ZONE:-$(printf '%s\n' "$LAB_DOMAIN" | awk -F. '{ print (NF>1) ? $(NF-1)"."$NF : $NF }')}"
# E-mail du compte ACME (Let's Encrypt refuse certains domaines d'exemple).
LAB_ACME_EMAIL="${LAB_ACME_EMAIL:-$(lire_lab_env LAB_ACME_EMAIL)}"
LAB_ACME_EMAIL="${LAB_ACME_EMAIL:-admin@${LAB_DNS_ZONE}}"

# --- Mode TLS : auto-signé (défaut) ou cert-manager + Let's Encrypt ----------
# Le défaut versionné est `kubeadm.lab.example.io`, un domaine d'exemple : sans domaine
# RÉEL et sans token Cloudflare, le chemin ACME ne peut de toute façon rien émettre et
# le lab reste sans TLS. L'auto-signé, lui, marche partout et hors-ligne — c'est donc
# le bon défaut « ça démarre ». On ne passe à ACME que quand on a vraiment un domaine.
SELF_SIGNED="${SELF_SIGNED:-$(lire_lab_env SELF_SIGNED)}"
SELF_SIGNED="${SELF_SIGNED:-true}"
# Tolérant sur la casse : `True`/`TRUE`/`true` sont le même « oui ».
SELF_SIGNED="$(printf '%s' "$SELF_SIGNED" | tr '[:upper:]' '[:lower:]')"
case "$SELF_SIGNED" in
  true|false) ;;
  *) echo "ERREUR : SELF_SIGNED='${SELF_SIGNED}' inconnu (true|false)." >&2 ; exit 1 ;;
esac

# --- Émetteur ACME : staging par défaut, production sur demande --------------
# (ignoré quand SELF_SIGNED=true : aucun ACME n'entre en jeu)
# Le wildcard ne vit QUE dans etcd : `vagrant destroy` le détruit, et le rebuild en
# redemande un neuf. Or Let's Encrypt PRODUCTION plafonne à 5 certificats par semaine
# pour un même jeu d'identifiants (`*.<LAB_DOMAIN>`) — un lab jetable épuise ce quota en
# 5 rebuilds, puis se retrouve sans TLS pendant des heures (erreur 429, cf. README).
# Le staging a un quota ~30 000/semaine : c'est le bon défaut pour un lab. On ne passe en
# production que si on en a explicitement besoin (cert trusté par le navigateur).
LAB_ACME_ISSUER="${LAB_ACME_ISSUER:-$(lire_lab_env LAB_ACME_ISSUER)}"
LAB_ACME_ISSUER="${LAB_ACME_ISSUER:-staging}"
case "$LAB_ACME_ISSUER" in
  staging|prod) ;;
  *) echo "ERREUR : LAB_ACME_ISSUER='${LAB_ACME_ISSUER}' inconnu (staging|prod)." >&2 ; exit 1 ;;
esac
ACME_ISSUER="letsencrypt-${LAB_ACME_ISSUER}"

# --- CNI : qui pose le réseau, et est-ce qu'on aura une IP LoadBalancer ? -----
# `kubeadm init` ne pose JAMAIS de réseau pod : les quatre branches ci-dessous partent
# donc toutes d'un cluster NotReady, et trois d'entre elles installent réellement un CNI.
#   cilium  -> Cilium + son pool L2 (annonce ARP)                         => IP LB ✅
#   calico  -> Calico via l'opérateur Tigera (CNI seul)                   => IP LB ❌
#   flannel -> flannel (CNI seul, minimaliste)                            => IP LB ❌
#   none    -> personne ne pose de CNI, c'est à toi                       => IP LB ❌
CNI="$(lire_param CNI cilium)"
case "$CNI" in
  cilium|calico|flannel|none) ;;
  *) echo "ERREUR : CNI='${CNI}' inconnu (cilium|calico|flannel|none)." >&2 ; exit 1 ;;
esac
# Seul Cilium annonce les IP de Service en L2 dans ce lab.
if [ "$CNI" = "cilium" ]; then LB_L2=1 ; else LB_L2=0 ; fi

# Plage d'IP LoadBalancer : la 1re IP est celle que prend le Gateway (cible du DNS wildcard).
LB_POOL_START="${LB_POOL_START:-$(lire_lab_env LB_POOL_START)}"
LB_POOL_START="${LB_POOL_START:-192.168.56.200}"

# Paramètres réseau relus du cluster réel — ne servent qu'à la branche flannel ci-dessous
# (cilium-up.sh et calico-up.sh les relisent eux-mêmes).
POD_CIDR="$(lire_param POD_CIDR 10.244.0.0/16)"
HOSTONLY_IF="$(lire_param HOSTONLY_IF eth1)"
KUBE_PROXY_REPLACEMENT="$(lire_param KUBE_PROXY_REPLACEMENT true)"
KUBE_PROXY_REPLACEMENT="$(printf '%s' "$KUBE_PROXY_REPLACEMENT" | tr '[:upper:]' '[:lower:]')"

# ⚠️ Le couple interdit. Avec KUBE_PROXY_REPLACEMENT=true, `kubeadm init` a tourné avec
# `--skip-phases=addon/kube-proxy` : il n'y a AUCUN kube-proxy dans le cluster. Seul Cilium
# sait le remplacer ici — avec calico/flannel/none, plus aucune ClusterIP ne répondrait
# (CoreDNS compris). cluster-up.sh refuse déjà ce couple au bootstrap ; on le revérifie
# parce que lab.env a pu être édité depuis, et que la panne serait très difficile à lire.
if [ "$KUBE_PROXY_REPLACEMENT" = "true" ] && [ "$CNI" != "cilium" ]; then
  echo "ERREUR : KUBE_PROXY_REPLACEMENT=true exige CNI=cilium (ici CNI=${CNI})." >&2
  echo "  Choisis CNI=cilium, ou KUBE_PROXY_REPLACEMENT=false + reconstruction du cluster" >&2
  echo "  (./kubeadm/cluster-reset.sh && ./kubeadm/cluster-up.sh)." >&2
  exit 1
fi

# --- Pré-requis -------------------------------------------------------------
requis="kubectl helm"
# openssl n'est nécessaire que pour fabriquer le wildcard auto-signé.
[ "$SELF_SIGNED" = "true" ] && requis="$requis openssl"
for bin in $requis; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable." >&2; exit 1; }
done
kubectl get --raw='/readyz' >/dev/null 2>&1 || { echo "ERREUR : apiserver injoignable (KUBECONFIG=${KUBECONFIG})." >&2; exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ============================================================================
log "[1/4] CNI = ${CNI}"
case "$CNI" in
  cilium)
    echo "    -> _k8s/cilium/cilium-up.sh (CNI + pool L2)"
    bash _k8s/cilium/cilium-up.sh
    ;;
  calico)
    echo "    -> _k8s/calico/calico-up.sh (CNI seul)"
    bash _k8s/calico/calico-up.sh
    echo "    /!\\ Calico n'annonce PAS les IP de Service LoadBalancer (BGP uniquement)."
    echo "        Le Gateway restera en EXTERNAL-IP <pending> et aucune UI ne sera"
    echo "        joignable tant que MetalLB n'est pas installé. Voir _k8s/calico/README.md."
    ;;
  flannel)
    # flannel n'a pas de dossier `_k8s/flannel/` : c'est le chemin DÉGRADÉ du lab (aucune
    # IP LoadBalancer, donc aucune UI joignable), il tient en quelques lignes ici.
    # Deux valeurs sont vitales et c'est tout l'intérêt de passer par le chart :
    #   - podCidr DOIT valoir le `networking.podSubnet` de kubeadm (le défaut du chart est
    #     10.244.0.0/16, qui se trouve être le nôtre — on ne PARIE pas là-dessus) ;
    #   - `--iface=<host-only>` épingle la bonne carte. Sans lui, flannel suit la route par
    #     défaut et prend la NAT 10.0.2.15, identique sur toutes les VM : les VTEP VXLAN
    #     pointent vers un NAT isolé et le trafic pod cross-node est cassé.
    # Version NON épinglée par défaut (contrairement au reste du dépôt) : ce chemin n'a pas
    # de dossier ni de README à maintenir. `FLANNEL_VERSION=v0.27.4 ./_k8s/platform-up.sh`
    # si tu veux de la reproductibilité.
    echo "    -> chart flannel/flannel (CNI seul, pas d'IP LoadBalancer)"
    helm repo add flannel https://flannel-io.github.io/flannel/ >/dev/null 2>&1 || true
    helm repo update flannel >/dev/null
    args_flannel=(upgrade --install flannel flannel/flannel
      -n kube-flannel --create-namespace
      --set "podCidr=${POD_CIDR}"
      --set-json "flannel.args=[\"--ip-masq\",\"--kube-subnet-mgr\",\"--iface=${HOSTONLY_IF}\"]")
    if [ -n "${FLANNEL_VERSION:-}" ]; then
      args_flannel+=(--version "${FLANNEL_VERSION}")
    fi
    helm "${args_flannel[@]}"
    echo "    attente des nodes Ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
    echo "    /!\\ flannel n'attribue aucune IP de Service LoadBalancer : le Gateway"
    echo "        restera en EXTERNAL-IP <pending>. Pour les UI HTTPS, utilise CNI=cilium."
    ;;
  none)
    echo "    CNI=none : aucun CNI installé, ni par kubeadm ni ici."
    kubectl get nodes --no-headers | grep -q ' Ready ' \
      || { echo "ERREUR : aucun node Ready — installe ton CNI avant de continuer." >&2; exit 1; }
    ;;
esac

log "[2/4] Envoy Gateway ${ENVOY_GW_VERSION} + main-gateway"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GW_VERSION}" -n envoy-gateway-system --create-namespace
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=180s
# Rend le manifeste : hostname de l'écouteur https + nom du Secret TLS depuis LAB_DOMAIN,
# et l'émetteur ACME depuis LAB_ACME_ISSUER (le manifeste versionné porte `staging`).
# En auto-signé, on RETIRE le bloc `annotations:` du Gateway (commentaires compris) :
# l'annotation `cert-manager.io/cluster-issuer` est ce qui déclenche la création d'un
# Certificate. La laisser en place ferait écraser notre Secret par cert-manager dès
# qu'il serait installé pour une autre raison.
rendre_envoy_proxy() {
  if [ "$SELF_SIGNED" = "true" ]; then
    remplacer_issuer='/^  annotations:/,\|^    cert-manager\.io/cluster-issuer:|d'
  else
    remplacer_issuer="s|\(cert-manager\.io/cluster-issuer:\)[[:space:]]*letsencrypt-[a-z]*|\1 ${ACME_ISSUER}|"
  fi
  sed -e "s/kubeadm\.lab\.example\.io/${LAB_DOMAIN}/g" \
      -e "s/kubeadm-lab-example-io/${LAB_DOMAIN_DASH}/g" \
      -e "$remplacer_issuer" \
      _k8s/envoy-gateway/Envoy-Proxy.yml
}
ip_gateway() {
  kubectl -n envoy-gateway-system get svc \
    -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' \
    2>/dev/null || true
}

if [ "$LB_L2" = "1" ]; then
  rendre_envoy_proxy | kubectl apply -f -
else
  # `loadBalancerClass: io.cilium/l2-announcer` est spécifique à Cilium : la laisser
  # empêcherait tout autre annonceur (MetalLB avec Calico) de servir ce Service.
  rendre_envoy_proxy | sed '/loadBalancerClass:/d' | kubectl apply -f -
fi

if [ "$LB_L2" = "1" ]; then
  echo "    attente de l'IP LoadBalancer (annonce L2, attendu ${LB_POOL_START})..."
  for _ in $(seq 1 30); do
    ip="$(ip_gateway)"
    [ -n "$ip" ] && break
    sleep 5
  done
  if [ -n "${ip:-}" ]; then
    echo "    Gateway EXTERNAL-IP = $ip"
  else
    echo "    /!\\ toujours en <pending> après 150 s. Vérifier le pool et l'annonce L2 :"
    echo "        kubectl get ciliumloadbalancerippool ; kubectl get ciliuml2announcementpolicy"
  fi
else
  echo "    Pas d'annonceur L2 avec CNI=${CNI} : le Service restera en <pending>."
  echo "    C'est attendu — installe MetalLB (cf. _k8s/calico/README.md) pour l'obtenir."
fi

log "[3/4] metrics-server (--kubelet-insecure-tls : certificats kubelet auto-signés)"
kubectl apply -f _k8s/metric-server.yaml

if [ "$SELF_SIGNED" = "true" ]; then

log "[4/4] Wildcard TLS auto-signé (openssl) — cert-manager NON installé"
echo "    -> _k8s/self-signed/selfsigned-up.sh (AC locale + cert *.${LAB_DOMAIN})"
bash _k8s/self-signed/selfsigned-up.sh

else

log "[4/4] cert-manager ${CERT_MANAGER_VERSION} + Cloudflare + ClusterIssuers"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --set crds.enabled=true \
  --set config.apiVersion="controller.config.cert-manager.io/v1alpha1" \
  --set config.kind="ControllerConfiguration" \
  --set config.enableGatewayAPI=true
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  kubectl create secret generic cloudflare-api-token -n cert-manager \
    --from-literal=api-token="${CLOUDFLARE_API_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "    /!\\ CLOUDFLARE_API_TOKEN vide (ni env ni lab.env) : secret NON créé."
  echo "        Le certificat wildcard restera en attente jusqu'à sa création."
fi
# ClusterIssuers : e-mail ACME + zone DNS du solveur substitués (cf. en-tête du script).
for issuer in 02-clusterissuer-staging 03-clusterissuer-prod; do
  sed -e "s/kubeadm\.lab\.example\.io/${LAB_DOMAIN}/g" \
      -e "s/admin@example\.io/${LAB_ACME_EMAIL}/g" \
      -e "s/^\([[:space:]]*-[[:space:]]\)example\.io/\1${LAB_DNS_ZONE}/" \
      "_k8s/cert-manager/${issuer}.yaml" | kubectl apply -f -
done

# --- Attente de l'émission du cert wildcard (DNS-01) pour un résumé fiable --
# Le cert + le Secret vivent dans le ns envoy-gateway-system (porté par main-gateway).
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  log "Attente de l'émission du certificat wildcard (DNS-01, ~1-2 min)..."
  for _ in $(seq 1 24); do
    r="$(kubectl -n envoy-gateway-system get certificate "${WILDCARD_TLS}" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [ "$r" = "True" ] && { echo "    cert Ready=True"; break; }
    sleep 10
  done
fi

fi   # fin de la bascule SELF_SIGNED

# ============================================================================
log "Plateforme installée."
echo "  CNI          : ${CNI}$([ "$LB_L2" = 1 ] && echo ' (annonce L2 des IP LoadBalancer)' || echo ' (pas d IP LoadBalancer)')"
echo "  kube-proxy   : $([ "$KUBE_PROXY_REPLACEMENT" = true ] && echo 'REMPLACÉ par Cilium (eBPF)' || echo 'installé par kubeadm')"
echo "  Nodes        : $(kubectl get nodes --no-headers | grep -c ' Ready ')/$(kubectl get nodes --no-headers | wc -l) Ready"
echo "  Gateway      : $(kubectl -n envoy-gateway-system get gateway main-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)"
if [ "$SELF_SIGNED" = "true" ]; then
  echo "  Cert wildcard: $(kubectl -n envoy-gateway-system get secret "${WILDCARD_TLS}" -o jsonpath='{.metadata.name}' 2>/dev/null || echo 'ABSENT') (auto-signé) [${WILDCARD_TLS}]"
  echo "  Mode TLS     : SELF_SIGNED=true — AC locale _out/self-signed/ca.crt, pas de cert-manager"
  echo "  Domaine      : *.${LAB_DOMAIN}  (aucun DNS public requis)"
  echo "                 Le navigateur avertit tant que l'AC n'est pas importée :"
  echo "                 sudo cp _out/self-signed/ca.crt /usr/local/share/ca-certificates/vagrant-kubeadm-lab.crt"
  echo "                 sudo update-ca-certificates"
  echo "                 Pour un cert publiquement trusté : SELF_SIGNED=false + CLOUDFLARE_API_TOKEN."
else
  echo "  Cert wildcard: $(kubectl -n envoy-gateway-system get certificate "${WILDCARD_TLS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo '?') (Ready) [${WILDCARD_TLS}]"
  echo "  Émetteur ACME: ${ACME_ISSUER}$([ "$LAB_ACME_ISSUER" = "staging" ] && echo '  (cert NON trusté : avertissement navigateur attendu)' || echo '  (cert trusté — quota 5/semaine !)')"
  echo "  Domaine      : *.${LAB_DOMAIN}  (zone DNS ${LAB_DNS_ZONE})"
  if [ "$LAB_ACME_ISSUER" = "staging" ]; then
    echo "                 Pour un cert trusté : LAB_ACME_ISSUER=prod dans lab.env, puis"
    echo "                 kubectl -n envoy-gateway-system delete secret ${WILDCARD_TLS}"
  fi
fi
echo
echo "  Addons à installer ensuite (chacun son dossier + up.sh) :"
echo "    Argo CD  : ./_k8s/argocd/argocd-up.sh          (GitOps, argo.${LAB_DOMAIN})"
echo "    Longhorn : voir _k8s/longhorn/README.md         (stockage bloc)"
echo "    Vault    : voir _k8s/vault-cluster/README.md    (secrets HA)"
echo
gw_ip="$(ip_gateway || true)"
gw_ip="${gw_ip:-$LB_POOL_START}"
if [ "$SELF_SIGNED" = "true" ]; then
  # Pas de contrainte ACME en auto-signé : le domaine n'a jamais besoin d'exister
  # publiquement, une résolution locale suffit à joindre les UI.
  echo "  Résolution des noms — à faire UNE FOIS pour joindre les UI :"
  echo "    ligne /etc/hosts (le plus simple, un sous-domaine par ligne) :"
  echo "      ${gw_ip}  argo.${LAB_DOMAIN} grafana.${LAB_DOMAIN} vault.${LAB_DOMAIN}"
  echo "    ou un enregistrement A wildcard  *.${LAB_DOMAIN} -> ${gw_ip}  si tu as une zone DNS."
else
  echo "  DNS — à faire UNE FOIS chez ton registrar/Cloudflare pour joindre les UI :"
  echo "    enregistrement A  *.${LAB_DOMAIN}  ->  ${gw_ip}"
  echo "    en DNS-only (nuage GRIS) : le proxy Cloudflare ne peut pas joindre une IP privée."
fi
