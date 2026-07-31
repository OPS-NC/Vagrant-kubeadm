#!/usr/bin/env bash
#
# node-join.sh — `kubeadm join` d'un node (control plane ou worker). Exécuté DANS la
# VM, appelé par kubeadm/cluster-up.sh depuis l'hôte :
#     vagrant ssh k8s-w1 -c "sudo NODE_NAME=k8s-w1 bash /vagrant/kubeadm/node-join.sh"
#
# Lit : /vagrant/_out/join-<NODE_NAME>.yaml  (rendu par cluster-up.sh)
#
# Idempotent : un node déjà membre du cluster est laissé tranquille.
set -euo pipefail

NODE_NAME="${NODE_NAME:-$(hostname)}"
OUT="/vagrant/_out"
CONFIG="${OUT}/join-${NODE_NAME}.yaml"

log() { printf '\n\033[1;36m[%s] ==> %s\033[0m\n' "$NODE_NAME" "$*"; }

[ -f "$CONFIG" ] || { echo "ERREUR : ${CONFIG} introuvable (cluster-up.sh doit le rendre d'abord)." >&2; exit 1; }

# `kubelet.conf` n'existe qu'après une jonction réussie : c'est le témoin le plus
# fiable, et il vaut aussi bien pour un worker que pour un control plane.
if [ -f /etc/kubernetes/kubelet.conf ]; then
  log 'Déjà membre du cluster — kubeadm join non relancé'
  exit 0
fi

log "kubeadm join"
kubeadm join --config "$CONFIG"

# Un control plane secondaire mérite son kubeconfig local : c'est ce qui permet de
# diagnostiquer depuis CE node quand le premier est tombé.
if [ -f /etc/kubernetes/admin.conf ]; then
  install -o root -g root -m 0600 -D /etc/kubernetes/admin.conf /root/.kube/config
  install -d -o vagrant -g vagrant -m 0700 /home/vagrant/.kube
  install -o vagrant -g vagrant -m 0600 /etc/kubernetes/admin.conf /home/vagrant/.kube/config
fi

log "Node joint au cluster."
