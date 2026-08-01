#!/usr/bin/env bash
#
# cluster-reset.sh — undoes the cluster (`kubeadm reset`) on every node, WITHOUT
# destroying the VMs. We start again from an already-done `vagrant up`: the packages,
# containerd and keepalived stay in place, only the Kubernetes state disappears.
#
#     ./kubeadm/cluster-reset.sh          # asks for confirmation
#     ./kubeadm/cluster-reset.sh --yes    # without confirmation
#
# When to use it rather than `vagrant destroy`:
#   - replay a failed bootstrap without paying 10 minutes of VM creation again;
#   - change POD_CIDR, SERVICE_CIDR, the CNI or the VIP (all frozen at `init` time).
#
# ⚠️ DESTRUCTIVE: etcd, the certificates and every workload of the cluster are lost.
#    So is whatever lives in a PersistentVolume backed by the node's disk.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

if [ -f "${REPO_DIR}/lab.env" ]; then
  while IFS='=' read -r key val || [ -n "$key" ]; do
    case "$key" in ''|\#*) continue ;; esac
    printf '%s' "$key" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$' || continue
    val="${val%%#*}"
    val="$(printf '%s' "$val" | tr -d '[:space:]"'"'")"
    eval ": \${$key:=\$val}"
  done < "${REPO_DIR}/lab.env"
fi

CONTROL_PLANES="${CONTROL_PLANES:-1}"
WORKERS="${WORKERS:-2}"
NODE_PREFIX="${NODE_PREFIX:-k8s}"
OUT="${OUT:-_out}"

command -v vagrant >/dev/null 2>&1 || { echo "ERROR: 'vagrant' not found." >&2; exit 1; }

nodes=()
for ((i = 1; i <= CONTROL_PLANES; i++)); do nodes+=("${NODE_PREFIX}-cp${i}"); done
for ((i = 1; i <= WORKERS;        i++)); do nodes+=("${NODE_PREFIX}-w${i}"); done

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# --- Confirmation ------------------------------------------------------------
if [ "${1:-}" != "--yes" ]; then
  cat <<EOF
⚠️  This will run 'kubeadm reset' on: ${nodes[*]}

    etcd, the certificates and every workload of the cluster will be LOST.
    The VMs themselves are not destroyed.

EOF
  printf "Confirm? (type 'yes'): "
  read -r answer
  [ "$answer" = "yes" ] || { echo "Cancelled." ; exit 0 ; }
fi

# --- Reset, workers first ----------------------------------------------------
# The workers before the control planes: a worker that withdraws while the API still
# answers deregisters cleanly, instead of leaving a ghost Node object behind.
for ((i = ${#nodes[@]} - 1; i >= 0; i--)); do
  node="${nodes[$i]}"
  # `|| true`: without it, a failing `vagrant status` would kill the reset under `set -e`
  # instead of simply reporting the VM as absent and moving on to the next one.
  state="$(vagrant status "$node" --machine-readable 2>/dev/null \
           | awk -F, '$3 == "state" {print $4; exit}' || true)"
  if [ "$state" != "running" ]; then
    echo "    - ${node}: skipped (${state:-nonexistent})"
    continue
  fi
  log "resetting ${node}"
  vagrant ssh "$node" -c "sudo bash /vagrant/kubeadm/node-reset.sh" -- -q -o LogLevel=ERROR \
    || echo "    /!\\ partial reset on ${node} — carrying on"
done

# --- Host-side cleanup -------------------------------------------------------
log "Cleaning up the host"
rm -rf "${REPO_DIR:?}/${OUT}"
rm -f  "${REPO_DIR}/kubeconfig"
echo "    ${OUT}/ and kubeconfig removed"

echo
echo "================================================================"
echo " Cluster undone. The VMs are still running."
echo "   To bring a cluster back up:  ./kubeadm/cluster-up.sh"
echo "================================================================"
