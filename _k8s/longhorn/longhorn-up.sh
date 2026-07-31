#!/usr/bin/env bash
#
# longhorn-up.sh — installe Longhorn (stockage bloc répliqué) sur le cluster kubeadm et
# expose son UI en HTTPS sous longhorn.$LAB_DOMAIN via main-gateway.
#
# Addon à part : platform-up.sh ne pose que Cilium + Envoy + metrics + le wildcard TLS.
#
# ⚠️ CE QUI A DISPARU DEPUIS LE LAB TALOS — c'est LE point à comprendre si tu viens de là.
#    Sur Talos, ce script commençait par deux étapes qu'on ne pouvait pas court-circuiter :
#      1. VÉRIFIER les extensions `iscsi-tools` / `util-linux-tools`. Une extension Talos est
#         CUITE dans l'image de l'installeur (`talosctl get extensions`) : un node sans elles
#         était irrécupérable sans réinstallation, d'où un échec AVANT de poser le chart.
#      2. Appliquer un montage kubelet `rshared` sur /var/lib/longhorn (`talosctl patch mc`),
#         parce que le kubelet Talos tourne dans un conteneur sans propagation de montage
#         bidirectionnelle.
#    Sur Debian, les deux tombent :
#      1. le prérequis iSCSI n'est plus une image système mais un PAQUET : `kubeadm/provision.sh`
#         fait `apt-get install -y open-iscsi nfs-common`, `systemctl enable --now iscsid` et
#         charge `iscsi_tcp` (/etc/modules-load.d/iscsi.conf) sur CHAQUE node, au provisioning ;
#      2. `/var/lib/longhorn` est un dossier ordinaire du système de fichiers racine et le
#         kubelet tourne directement sur l'hôte : la propagation de montage est déjà bonne.
#    Conséquence : plus de `talosctl`, plus de `TALOSCONFIG`, plus de `patch-longhorn.yaml`
#    ni de `schematic.yaml` (supprimés) — le script passe de 5 étapes à 3.
#
# Prérequis : plateforme en place (main-gateway HTTPS + Secret wildcard), helm.
# Idempotent : `helm upgrade --install` + `kubectl apply`. Relançable sans casse.
# À lancer depuis la racine du dépôt : ./_k8s/longhorn/longhorn-up.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"

# --- Version épinglée (overridable par variable d'env) ----------------------
LONGHORN_VERSION="${LONGHORN_VERSION:-1.12.0}"

# --- Lecture de lab.env -----------------------------------------------------
# `sed -n s///p` et JAMAIS `grep` : sans correspondance `grep` renvoie 1 et, sous
# `set -e` + `pipefail`, tuerait le script. `|| true` couvre l'absence de lab.env.
lire_lab_env() {
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" \
    "${REPO_DIR}/lab.env" 2>/dev/null | head -n1 | tr -d " \"'" || true
}

# --- Domaine du lab : défaut versionné NEUTRE (le dépôt est public) ----------
LAB_DOMAIN="${LAB_DOMAIN:-$(lire_lab_env LAB_DOMAIN)}"
LAB_DOMAIN="${LAB_DOMAIN:-kubeadm.lab.example.io}"

# --- Pré-requis -------------------------------------------------------------
for bin in kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable." >&2; exit 1; }
done
kubectl get --raw='/readyz' >/dev/null 2>&1 || { echo "ERREUR : apiserver injoignable (KUBECONFIG=${KUBECONFIG})." >&2; exit 1; }

# --- Nombre de nodes de stockage : DÉTECTÉ, pas déduit de lab.env ------------
# Les volumes Longhorn ne vivent que là où des pods peuvent se planifier — les workers
# dans le cas normal (les CP portent `node-role.kubernetes.io/control-plane:NoSchedule`).
# On interroge donc le cluster plutôt que de faire confiance à WORKERS de lab.env, qui
# n'exprime qu'une intention.
# Cas WORKERS=0 : topologie SUPPORTÉE ici (`UNTAINT_CP=auto` déteinte alors les control
# planes, cf. lab.env) — ils deviennent les seuls nodes de stockage, on les compte.
# `|| true` : sous `pipefail`, un pipeline en échec ferait échouer l'affectation et, sous
# `set -e`, tuerait le script — même piège que `grep` plus haut.
STORAGE_NODES="$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)"
if [ "${STORAGE_NODES:-0}" -eq 0 ]; then
  STORAGE_NODES="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)"
fi
[ "${STORAGE_NODES:-0}" -gt 0 ] || { echo "ERREUR : aucun node planifiable — Longhorn n'a nulle part où stocker." >&2; exit 1; }

# Nb de réplicas bloc = nb de nodes de stockage, plafonné à 3 : `defaultReplicaCount` > nb
# de nodes laisse tous les volumes « Degraded » à vie (piège documenté du README).
REPLICAS="${REPLICAS:-$STORAGE_NODES}"
[ "$REPLICAS" -gt 3 ] && REPLICAS=3

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ============================================================================
log "[1/3] Namespace longhorn-system (PodSecurity privileged)"
# Les pods Longhorn sont privilégiés (iSCSI, hostPath). L'admission PodSecurity n'applique
# rien par défaut sur un cluster kubeadm, mais l'étiquette documente l'intention et garde le
# namespace fonctionnel si le cluster est durci plus tard (--admission-control-config-file).
kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite

# ============================================================================
log "[2/3] Chart Longhorn ${LONGHORN_VERSION} (${REPLICAS} réplica(s) bloc, ${STORAGE_NODES} node(s) de stockage) + StorageClass longhorn-r1"
helm repo add longhorn https://charts.longhorn.io >/dev/null 2>&1 || true
helm repo update longhorn >/dev/null
# values.yaml porte 3 réplicas (topologie « pleine » du lab) ; on l'aligne sur le nombre de
# nodes de stockage réellement présents.
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version "${LONGHORN_VERSION}" \
  --values _k8s/longhorn/values.yaml \
  --set "defaultSettings.defaultReplicaCount=${REPLICAS}" \
  --set "persistence.defaultClassReplicaCount=${REPLICAS}" \
  --wait --timeout 10m
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer --timeout=300s
kubectl apply -f _k8s/longhorn/longhorn-r1-storageclass.yaml

# ============================================================================
log "[3/3] HTTPRoute longhorn.${LAB_DOMAIN}"
# Le manifeste versionné porte le domaine neutre : substitué à la volée, comme
# partout ailleurs dans _k8s/ (cf. ../README.md).
sed "s/kubeadm\.lab\.example\.io/${LAB_DOMAIN}/g" _k8s/longhorn/httproute.yaml | kubectl apply -f -

# ============================================================================
log "Longhorn installé."
echo "  StorageClass : longhorn (${REPLICAS} réplica(s), défaut du cluster) + longhorn-r1 (1 réplica)"
echo "  UI           : https://longhorn.${LAB_DOMAIN}   (AUCUNE authentification !)"
echo "  Sans exposer : kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80"
echo "  Vérifier     : kubectl -n longhorn-system get nodes.longhorn.io"
echo
echo "  /!\\ L'UI Longhorn n'a aucune auth et permet de SUPPRIMER des volumes : ne l'expose"
echo "      qu'en réseau de confiance, ou pose une SecurityPolicy Envoy (cf. README)."
