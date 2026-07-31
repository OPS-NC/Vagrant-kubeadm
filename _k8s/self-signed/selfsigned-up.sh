#!/usr/bin/env bash
#
# selfsigned-up.sh — pose le wildcard TLS `*.<LAB_DOMAIN>` du lab SANS cert-manager,
# sans Let's Encrypt, sans token Cloudflare et sans domaine publiquement résolvable.
#
# Fait trois choses (chacune suppose la précédente) :
#   1. Une AC locale (`_out/self-signed/ca.crt` + `ca.key`, 10 ans), générée UNE FOIS
#      et RÉUTILISÉE ensuite : c'est elle qu'on importe dans son navigateur / son
#      trousseau. Elle survit à `vagrant destroy` (elle vit sur l'hôte, pas dans etcd),
#      donc l'exception de sécurité ne se rejoue pas à chaque rebuild.
#   2. Un certificat feuille `*.<LAB_DOMAIN>` (+ `<LAB_DOMAIN>`) signé par cette AC,
#      825 jours, régénéré seulement si absent / expirant / domaine changé.
#   3. Le Secret TLS `wildcard-<domaine-en-tirets>-tls` dans `envoy-gateway-system`,
#      exactement le nom qu'attend l'écouteur `https` de `main-gateway` — cert-manager
#      aurait rempli le MÊME Secret, la Gateway n'a donc rien à savoir de tout ça.
#
# Appelé par _k8s/platform-up.sh (étape 4) quand SELF_SIGNED=true, mais lançable seul :
#   ./_k8s/self-signed/selfsigned-up.sh
# Idempotent : relancé, il réutilise l'AC et le certificat tant qu'ils sont valides.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"

# Durées de vie. 825 jours = la limite au-delà de laquelle les navigateurs refusent
# un certificat serveur, même signé par une AC de confiance.
CA_DAYS="${CA_DAYS:-3650}"
CERT_DAYS="${CERT_DAYS:-825}"
# Marge de renouvellement : en dessous, on régénère la feuille au prochain passage.
RENEW_DAYS="${RENEW_DAYS:-30}"

# --- Lecture de lab.env ------------------------------------------------------
# `sed -n s///p` et JAMAIS `grep` : sans correspondance `grep` renvoie 1 et, sous
# `set -e` + `pipefail`, tuerait le script. Le `|| true` couvre l'absence de lab.env
# (où `sed` sort en 2).
lire_lab_env() {
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" \
    "${REPO_DIR}/lab.env" 2>/dev/null | head -n1 | tr -d " \"'" || true
}
LAB_DOMAIN="${LAB_DOMAIN:-$(lire_lab_env LAB_DOMAIN)}"
LAB_DOMAIN="${LAB_DOMAIN:-kubeadm.lab.example.io}"
# Même dérivation que dans platform-up.sh : le nom du Secret suit le domaine.
LAB_DOMAIN_DASH="${LAB_DOMAIN//./-}"
WILDCARD_TLS="wildcard-${LAB_DOMAIN_DASH}-tls"

# `_out/` est gitignoré : la clé privée de l'AC ne peut pas partir dans un commit.
CERT_DIR="${REPO_DIR}/_out/self-signed"
CA_KEY="${CERT_DIR}/ca.key"
CA_CRT="${CERT_DIR}/ca.crt"
TLS_KEY="${CERT_DIR}/tls.key"
TLS_CRT="${CERT_DIR}/tls.crt"

# --- Pré-requis --------------------------------------------------------------
for bin in kubectl openssl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable." >&2; exit 1; }
done
kubectl get --raw='/readyz' >/dev/null 2>&1 || { echo "ERREUR : apiserver injoignable (KUBECONFIG=${KUBECONFIG})." >&2; exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

# ============================================================================
# 1. AC locale — générée une seule fois, puis réutilisée telle quelle.
# ============================================================================
if [ -s "$CA_KEY" ] && [ -s "$CA_CRT" ]; then
  log "AC locale : réutilisation de ${CA_CRT#"$REPO_DIR"/}"
else
  log "AC locale : génération (${CA_DAYS} jours)"
  openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days "$CA_DAYS" \
    -keyout "$CA_KEY" -out "$CA_CRT" \
    -subj "/O=Vagrant-KubeADM lab/CN=Vagrant-KubeADM self-signed CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  chmod 600 "$CA_KEY"
fi

# ============================================================================
# 2. Certificat feuille `*.<LAB_DOMAIN>` — régénéré seulement s'il le faut.
# ============================================================================
# Trois raisons de régénérer : le fichier manque, il expire dans moins de
# RENEW_DAYS, ou LAB_DOMAIN a changé depuis (le SAN ne couvre plus le lab).
besoin_cert=0
if [ ! -s "$TLS_CRT" ] || [ ! -s "$TLS_KEY" ]; then
  besoin_cert=1
elif ! openssl x509 -in "$TLS_CRT" -noout -checkend "$((RENEW_DAYS * 86400))" >/dev/null 2>&1; then
  echo "    certificat expirant sous ${RENEW_DAYS} jours -> régénération"
  besoin_cert=1
elif ! openssl x509 -in "$TLS_CRT" -noout -ext subjectAltName 2>/dev/null \
       | grep -Fq "DNS:*.${LAB_DOMAIN}"; then
  echo "    LAB_DOMAIN a changé (SAN ne couvre pas *.${LAB_DOMAIN}) -> régénération"
  besoin_cert=1
fi

if [ "$besoin_cert" = "1" ]; then
  log "Certificat *.${LAB_DOMAIN} (${CERT_DAYS} jours, signé par l'AC locale)"
  ext_file="$(mktemp)"
  csr_file="$(mktemp)"
  trap 'rm -f "$ext_file" "$csr_file"' EXIT
  # `serverAuth` + un SAN explicite : depuis longtemps les navigateurs ignorent le CN
  # et ne regardent QUE le subjectAltName. On couvre le wildcard ET l'apex, sinon
  # `https://<LAB_DOMAIN>` (sans sous-domaine) tomberait en erreur de nom.
  cat >"$ext_file" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:*.${LAB_DOMAIN},DNS:${LAB_DOMAIN}
EOF
  openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$TLS_KEY" -out "$csr_file" \
    -subj "/O=Vagrant-KubeADM lab/CN=*.${LAB_DOMAIN}" 2>/dev/null
  openssl x509 -req -in "$csr_file" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$TLS_CRT" -days "$CERT_DAYS" -sha256 -extfile "$ext_file" 2>/dev/null
  chmod 600 "$TLS_KEY"
  rm -f "$ext_file" "$csr_file"
  trap - EXIT
else
  log "Certificat *.${LAB_DOMAIN} : encore valide, réutilisé"
fi

# ============================================================================
# 3. Secret TLS dans le namespace de la Gateway.
# ============================================================================
# `tls.crt` = feuille PUIS AC : Envoy sert la chaîne complète, ce qui permet à un
# client ayant l'AC dans son magasin de valider sans autre configuration.
log "Secret ${WILDCARD_TLS} (ns envoy-gateway-system)"
kubectl create namespace envoy-gateway-system \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
chain_file="$(mktemp)"
trap 'rm -f "$chain_file"' EXIT
cat "$TLS_CRT" "$CA_CRT" >"$chain_file"
kubectl create secret tls "$WILDCARD_TLS" -n envoy-gateway-system \
  --cert="$chain_file" --key="$TLS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f "$chain_file"
trap - EXIT

# ============================================================================
log "Wildcard auto-signé en place."
echo "  Domaine  : *.${LAB_DOMAIN} (+ ${LAB_DOMAIN})"
echo "  Expire   : $(openssl x509 -in "$TLS_CRT" -noout -enddate | cut -d= -f2)"
echo "  Secret   : ${WILDCARD_TLS} (ns envoy-gateway-system)"
echo "  AC       : ${CA_CRT#"$REPO_DIR"/}"
echo
echo "  Le navigateur avertira tant que l'AC n'est pas dans ton magasin de confiance."
echo "  Pour supprimer l'avertissement une bonne fois (Linux, Debian/Ubuntu) :"
echo "    sudo cp ${CA_CRT#"$REPO_DIR"/} /usr/local/share/ca-certificates/vagrant-kubeadm-lab.crt"
echo "    sudo update-ca-certificates"
echo "  Firefox a son propre magasin : Paramètres > Vie privée > Certificats > Autorités."
