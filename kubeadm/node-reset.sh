#!/usr/bin/env bash
#
# node-reset.sh — puts ONE node back into the "ready for kubeadm" state, run INSIDE the VM.
# Called by kubeadm/cluster-reset.sh.
#
# `kubeadm reset` does the bulk of it but deliberately leaves behind what it did not lay
# down: the interfaces and the rules created by the CNI. Without this cleanup, a following
# `kubeadm init` inherits a ghost datapath and the pod network behaves inexplicably — the
# classic "I am rebuilding my lab" trap.
set -euo pipefail

log() { printf '\n\033[1;36m[%s] ==> %s\033[0m\n' "$(hostname)" "$*"; }

log "kubeadm reset"
kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock || true

log "Cleaning up the CNI datapath"
rm -rf /etc/cni/net.d/* 2>/dev/null || true

# Interfaces left behind by this lab's CNIs: Cilium (cilium_*, lxc*), flannel, Calico.
for i in cilium_host cilium_net cilium_vxlan flannel.1 cni0 vxlan.calico kube-ipvs0; do
  ip link delete "$i" 2>/dev/null || true
done
# The filtering is done by `awk`, NOT by `grep`: with no match `grep` exits 1 and, under
# `set -e` + `pipefail`, would kill the script HERE — that is, BEFORE the eBPF, iptables
# and etcd cleanup that follows. And the absence of an `lxc*`/`cali*` interface is the
# NORMAL case (Cilium in pure tunnel mode, a replayed reset, a CNI never laid down): so the
# script died most of the time, and `cluster-reset.sh` hid the failure behind "partial
# reset".
ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^(lxc|cali)/ {print $2}' \
  | while read -r i; do ip link delete "$i" 2>/dev/null || true; done

# eBPF programs pinned by Cilium: they SURVIVE the removal of the DaemonSet and keep
# intercepting the traffic of a cluster that no longer exists.
rm -rf /sys/fs/bpf/tc/globals/cilium_* 2>/dev/null || true

# kube-proxy's iptables/ipvs rules. `kubeadm reset` reports them but does not remove them.
iptables-save 2>/dev/null | grep -viE 'KUBE-|CILIUM_|cali-' | iptables-restore 2>/dev/null || true
ipvsadm --clear 2>/dev/null || true

log "Cleaning up the residual state"
rm -rf /var/lib/etcd/* /var/lib/cni/* /run/flannel 2>/dev/null || true
systemctl restart containerd 2>/dev/null || true

log "Node reset."
