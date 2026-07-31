#!/usr/bin/env bash
#
# node-reset.sh — remet UN node dans l'état « prêt pour kubeadm », exécuté DANS la VM.
# Appelé par kubeadm/cluster-reset.sh.
#
# `kubeadm reset` fait l'essentiel mais laisse volontairement derrière lui ce qu'il
# n'a pas posé : les interfaces et les règles créées par le CNI. Sans ce ménage, un
# `kubeadm init` suivant hérite d'un datapath fantôme et le réseau pod se comporte de
# façon inexplicable — c'est le piège classique du « je reconstruis mon lab ».
set -euo pipefail

log() { printf '\n\033[1;36m[%s] ==> %s\033[0m\n' "$(hostname)" "$*"; }

log "kubeadm reset"
kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock || true

log "Nettoyage du datapath CNI"
rm -rf /etc/cni/net.d/* 2>/dev/null || true

# Interfaces laissées par les CNI de ce lab : Cilium (cilium_*, lxc*), flannel, Calico.
for i in cilium_host cilium_net cilium_vxlan flannel.1 cni0 vxlan.calico kube-ipvs0; do
  ip link delete "$i" 2>/dev/null || true
done
# Le filtrage est fait par `awk`, PAS par `grep` : sans correspondance `grep` sort en 1
# et, sous `set -e` + `pipefail`, tuerait le script ICI — c'est-à-dire AVANT le nettoyage
# eBPF, iptables et etcd qui suit. Or l'absence d'interface `lxc*`/`cali*` est le cas
# NORMAL (Cilium en tunnel pur, reset rejoué, CNI jamais posé) : le script mourait donc
# la plupart du temps, et `cluster-reset.sh` masquait la panne derrière « reset partiel ».
ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^(lxc|cali)/ {print $2}' \
  | while read -r i; do ip link delete "$i" 2>/dev/null || true; done

# Programmes eBPF épinglés par Cilium : ils SURVIVENT au retrait du DaemonSet et
# continuent d'intercepter le trafic d'un cluster qui n'existe plus.
rm -rf /sys/fs/bpf/tc/globals/cilium_* 2>/dev/null || true

# Règles iptables/ipvs de kube-proxy. `kubeadm reset` les signale mais ne les retire pas.
iptables-save 2>/dev/null | grep -viE 'KUBE-|CILIUM_|cali-' | iptables-restore 2>/dev/null || true
ipvsadm --clear 2>/dev/null || true

log "Nettoyage des états résiduels"
rm -rf /var/lib/etcd/* /var/lib/cni/* /run/flannel 2>/dev/null || true
systemctl restart containerd 2>/dev/null || true

log "Node remis à zéro."
