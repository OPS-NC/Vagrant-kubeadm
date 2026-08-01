#!/usr/bin/env bash
#
# node-join.sh — `kubeadm join` of a node (control plane or worker). Run INSIDE the VM,
# called by kubeadm/cluster-up.sh from the host:
#     vagrant ssh k8s-w1 -c "sudo NODE_NAME=k8s-w1 bash /vagrant/kubeadm/node-join.sh"
#
# Reads: /vagrant/_out/join-<NODE_NAME>.yaml  (rendered by cluster-up.sh)
#
# Idempotent: a node that is already a cluster member is left alone.
set -euo pipefail

NODE_NAME="${NODE_NAME:-$(hostname)}"
OUT="/vagrant/_out"
CONFIG="${OUT}/join-${NODE_NAME}.yaml"

log() { printf '\n\033[1;36m[%s] ==> %s\033[0m\n' "$NODE_NAME" "$*"; }

[ -f "$CONFIG" ] || { echo "ERROR: ${CONFIG} not found (cluster-up.sh must render it first)." >&2; exit 1; }

# `kubelet.conf` only exists after a successful join: it is the most reliable witness, and
# it holds for a worker just as much as for a control plane.
if [ -f /etc/kubernetes/kubelet.conf ]; then
  log 'Already a cluster member — kubeadm join not re-run'
  exit 0
fi

log "kubeadm join"
kubeadm join --config "$CONFIG"

# A secondary control plane deserves its local kubeconfig: that is what lets you diagnose
# from THIS node when the first one is down.
if [ -f /etc/kubernetes/admin.conf ]; then
  install -o root -g root -m 0600 -D /etc/kubernetes/admin.conf /root/.kube/config
  install -d -o vagrant -g vagrant -m 0700 /home/vagrant/.kube
  install -o vagrant -g vagrant -m 0600 /etc/kubernetes/admin.conf /home/vagrant/.kube/config
fi

log "Node joined to the cluster."
