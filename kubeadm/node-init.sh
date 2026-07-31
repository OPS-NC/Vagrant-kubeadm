#!/usr/bin/env bash
#
# node-init.sh — `kubeadm init` sur le PREMIER control plane. Exécuté DANS la VM,
# appelé par kubeadm/cluster-up.sh depuis l'hôte :
#     vagrant ssh k8s-cp1 -c "sudo bash /vagrant/kubeadm/node-init.sh"
#
# La logique vit ici, dans un fichier versionné, plutôt que dans une longue commande
# passée à `vagrant ssh -c` : c'est lisible, ça se relit dans un diff, et surtout ça
# évite l'enfer de l'échappement de guillemets à travers deux couches de shell.
#
# Lit  : /vagrant/_out/kubeadm-init.yaml   (rendu par cluster-up.sh)
# Écrit: /vagrant/_out/admin.conf          (kubeconfig, récupéré par l'hôte)
#        /vagrant/_out/join.env            (token, empreinte CA, clé de certificats)
#
# Idempotent : si le control plane est DÉJÀ initialisé, on ne relance pas `init`
# (ce serait destructeur) — on se contente de régénérer les éléments de jonction.
set -euo pipefail

OUT="/vagrant/_out"
CONFIG="${OUT}/kubeadm-init.yaml"
SKIP_PHASES="${SKIP_PHASES:-}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

[ -f "$CONFIG" ] || { echo "ERREUR : ${CONFIG} introuvable (cluster-up.sh doit le rendre d'abord)." >&2; exit 1; }

# ============================================================================
if [ -f /etc/kubernetes/admin.conf ]; then
  log 'Control plane DÉJÀ initialisé — kubeadm init non relancé'
  echo "    Le relancer sur un cluster en route le détruirait. Pour repartir de zéro :"
  echo "      ./kubeadm/cluster-reset.sh    (ou vagrant destroy -f && vagrant up)"
else
  log "kubeadm init${SKIP_PHASES:+ (phases ignorées : ${SKIP_PHASES})}"
  # `--upload-certs` : dépose les CA du cluster dans le Secret `kubeadm-certs`, chiffré
  # par la clé de certificats. C'est ce qui permet aux autres control planes de
  # rejoindre sans qu'on recopie /etc/kubernetes/pki à la main.
  kubeadm init \
    --config "$CONFIG" \
    --upload-certs \
    ${SKIP_PHASES:+--skip-phases="$SKIP_PHASES"}
fi

# ============================================================================
log "kubeconfig pour root et pour l'utilisateur vagrant"
install -o root -g root -m 0600 -D /etc/kubernetes/admin.conf /root/.kube/config
install -d -o vagrant -g vagrant -m 0700 /home/vagrant/.kube
install -o vagrant -g vagrant -m 0600 /etc/kubernetes/admin.conf /home/vagrant/.kube/config

# ============================================================================
log "Éléments de jonction (token, empreinte CA, clé de certificats)"
# Le token créé par `init` expire en 24 h et la clé de certificats en 2 h. On en
# régénère systématiquement : cluster-up.sh peut être relancé longtemps après le `init`
# (typiquement pour ajouter un node), et un élément périmé produit une erreur de
# jonction particulièrement opaque.
join_cmd="$(kubeadm token create --print-join-command)"
# Forme attendue :
#   kubeadm join <ip>:6443 --token <t> --discovery-token-ca-cert-hash sha256:<h>
token="$(printf '%s\n' "$join_cmd" | sed -n 's/.*--token \([^ ]*\).*/\1/p')"
ca_hash="$(printf '%s\n' "$join_cmd" | sed -n 's/.*--discovery-token-ca-cert-hash sha256:\([^ ]*\).*/\1/p')"

# `upload-certs` rechiffre le Secret kubeadm-certs et imprime la nouvelle clé en
# dernière ligne. Rejouable sans risque sur un cluster en route.
# On extrait la clé par sa FORME (64 caractères hexadécimaux) plutôt que par sa
# position : `tail -n1` casserait au premier message ajouté en fin de phase par une
# future version de kubeadm, et l'erreur serait très difficile à relier à sa cause.
# `|| true` : sans correspondance, `grep` renvoie 1 et, sous `pipefail`, tuerait le
# script AVANT le contrôle explicite qui suit — lequel produit un bien meilleur message.
cert_key="$(kubeadm init phase upload-certs --upload-certs \
             | grep -Eo '^[a-f0-9]{64}$' | tail -n1 || true)"

if [ -z "$token" ] || [ -z "$ca_hash" ] || [ -z "$cert_key" ]; then
  echo "ERREUR : impossible d'extraire les éléments de jonction." >&2
  echo "         join_cmd = ${join_cmd}" >&2
  exit 1
fi

mkdir -p "$OUT"
umask 077
cat >"${OUT}/join.env" <<EOF
TOKEN=${token}
CA_HASH=${ca_hash}
CERT_KEY=${cert_key}
EOF
cp -f /etc/kubernetes/admin.conf "${OUT}/admin.conf"
chmod 0600 "${OUT}/join.env" "${OUT}/admin.conf" 2>/dev/null || true

log "Control plane initialisé."
echo "    Les nodes resteront NotReady tant qu'aucun CNI n'est posé — c'est NORMAL."
