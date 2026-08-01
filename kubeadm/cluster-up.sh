#!/usr/bin/env bash
#
# cluster-up.sh — chains the kubeadm commands that bring the cluster up
# (init -> join the control planes -> join the workers -> kubeconfig) after `vagrant up`.
#
# Run it from the repository root:
#     ./kubeadm/cluster-up.sh
#
# The topology comes from lab.env (the single source shared with the Vagrantfile). It can
# be overridden case by case through an environment variable:
#     CONTROL_PLANES=3 WORKERS=3 ./kubeadm/cluster-up.sh
#
# IDEMPOTENT, and this is also how you GROW the lab: add nodes to lab.env, `vagrant up`,
# then re-run this script — it skips what is already in place and only joins the new
# nodes.
#
# The script does NOTHING inside the VMs itself: it renders the configurations into
# `_out/` (visible from the VMs through the /vagrant synced folder) then calls
# kubeadm/node-init.sh and kubeadm/node-join.sh over `vagrant ssh`.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

# --- Topology: single source lab.env (shared with the Vagrantfile) ----------
# Loaded WITHOUT overwriting an already exported variable: a command-line override stays
# in charge. The key name is validated before any `eval` — a hand-mangled lab.env must not
# be able to run arbitrary code.
if [ -f "${REPO_DIR}/lab.env" ]; then
  while IFS='=' read -r key val || [ -n "$key" ]; do
    case "$key" in ''|\#*) continue ;; esac
    case "$key" in [A-Za-z_]*) ;; *) continue ;; esac
    printf '%s' "$key" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$' || continue
    val="${val%%#*}"                                    # trailing comment
    val="$(printf '%s' "$val" | tr -d '[:space:]"'"'")" # whitespace and quotes
    eval ": \${$key:=\$val}"
  done < "${REPO_DIR}/lab.env"
fi

# --- Parameters (defaults = safety net if lab.env is missing) ---------------
# ⚠️ These defaults MUST stay aligned with the Vagrantfile's and lab.env.example's.
CONTROL_PLANES="${CONTROL_PLANES:-1}"
WORKERS="${WORKERS:-2}"
NETWORK="${NETWORK:-192.168.56}"
VIP="${VIP:-${NETWORK}.5}"
CLUSTER_NAME="${CLUSTER_NAME:-kubeadm-lab}"
NODE_PREFIX="${NODE_PREFIX:-k8s}"
K8S_VERSION="${K8S_VERSION:-1.36.3}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
CNI="${CNI:-cilium}"
KUBE_PROXY_REPLACEMENT="${KUBE_PROXY_REPLACEMENT:-true}"
UNTAINT_CP="${UNTAINT_CP:-auto}"
CP_IP_START="${CP_IP_START:-10}"  ; CP_IP_STEP="${CP_IP_STEP:-10}"
WK_IP_START="${WK_IP_START:-101}" ; WK_IP_STEP="${WK_IP_STEP:-1}"
OUT="${OUT:-_out}"

WAIT_API="${WAIT_API:-600}"   # apiserver reachable after `kubeadm init`

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# --- Prerequisites ----------------------------------------------------------
for bin in vagrant kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH." >&2; exit 1; }
done

# --- Configuration coherence ------------------------------------------------
case "$CNI" in cilium|calico|flannel|none) ;; *)
  echo "ERROR: CNI='${CNI}' unknown (cilium|calico|flannel|none)." >&2 ; exit 1 ;; esac

KUBE_PROXY_REPLACEMENT="$(printf '%s' "$KUBE_PROXY_REPLACEMENT" | tr '[:upper:]' '[:lower:]')"
case "$KUBE_PROXY_REPLACEMENT" in true|false) ;; *)
  echo "ERROR: KUBE_PROXY_REPLACEMENT='${KUBE_PROXY_REPLACEMENT}' unknown (true|false)." >&2 ; exit 1 ;; esac

# Without kube-proxy AND without a replacement, NO Service works — not even CoreDNS
# reaching the API. Only Cilium can replace it in this lab, so we refuse the combination
# instead of delivering a silently unusable cluster.
if [ "$KUBE_PROXY_REPLACEMENT" = "true" ] && [ "$CNI" != "cilium" ]; then
  cat >&2 <<EOF
ERROR: KUBE_PROXY_REPLACEMENT=true requires CNI=cilium (currently CNI=${CNI}).

  With that combination, cluster-up.sh would skip installing kube-proxy while
  ${CNI} cannot replace it: no ClusterIP would answer any more.

  Two ways out, in lab.env:
    - CNI=cilium                     (keep the eBPF replacement, the repo default)
    - KUBE_PROXY_REPLACEMENT=false   (keep kube-proxy and ${CNI})
EOF
  exit 1
fi

if [ "$CONTROL_PLANES" -lt 1 ]; then
  echo "ERROR: CONTROL_PLANES=${CONTROL_PLANES} — at least 1 is required." >&2 ; exit 1
fi
if [ $((CONTROL_PLANES % 2)) -eq 0 ]; then
  echo "ERROR: CONTROL_PLANES=${CONTROL_PLANES} is EVEN. etcd requires an odd number" >&2
  echo "       to hold a useful quorum (1, 3, 5): with 2 members, losing a single" >&2
  echo "       node freezes the API." >&2
  exit 1
fi

# --- Computing the IPs and the names ----------------------------------------
cp_names=() ; cp_ips=() ; wk_names=() ; wk_ips=()
for ((i = 1; i <= CONTROL_PLANES; i++)); do
  cp_names+=("${NODE_PREFIX}-cp${i}")
  cp_ips+=("${NETWORK}.$((CP_IP_START + (i - 1) * CP_IP_STEP))")
done
for ((i = 1; i <= WORKERS; i++)); do
  wk_names+=("${NODE_PREFIX}-w${i}")
  wk_ips+=("${NETWORK}.$((WK_IP_START + (i - 1) * WK_IP_STEP))")
done
first_cp="${cp_names[0]}" ; first_cp_ip="${cp_ips[0]}"

echo "==> Topology   : ${CONTROL_PLANES} control plane(s) + ${WORKERS} worker(s)"
echo "    control    : $(IFS=' '; echo "${cp_names[*]}") -> $(IFS=' '; echo "${cp_ips[*]}")"
echo "    workers    : ${wk_names[*]:-none} -> ${wk_ips[*]:-}"
echo "==> API        : https://${VIP}:6443   (keepalived VIP)"
echo "==> Kubernetes : v${K8S_VERSION} — CNI=${CNI}, kube-proxy $([ "$KUBE_PROXY_REPLACEMENT" = true ] && echo 'REPLACED by Cilium (eBPF)' || echo 'installed')"

# --- Are the VMs running? ----------------------------------------------------
# Diagnosing it here costs a second; diagnosing it later means a `vagrant ssh` timing out
# in the middle of a half-finished `join`.
missing=()
for n in "${cp_names[@]}" "${wk_names[@]:-}"; do
  [ -z "$n" ] && continue
  # `|| true`: if `vagrant status` fails (VM absent from the index, VirtualBox missing,
  # NODE_PREFIX changed), `set -e` would kill the script WITHOUT a message — while the
  # whole block below exists precisely to say "run vagrant up first".
  state="$(vagrant status "$n" --machine-readable 2>/dev/null \
           | awk -F, '$3 == "state" {print $4; exit}' || true)"
  [ "$state" = "running" ] || missing+=("${n} (${state:-nonexistent})")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "ERROR: these VMs are not running: ${missing[*]}" >&2
  echo "       Run this first:  vagrant up" >&2
  exit 1
fi

mkdir -p "$OUT"

# Runs a command in a VM. `-q` and LogLevel=ERROR so the script's output stays readable
# (otherwise OpenSSH comments on every connection).
on_node() {
  local node="$1" ; shift
  vagrant ssh "$node" -c "$*" -- -q -o LogLevel=ERROR
}

# Rendering a template: substitution of the @NAME@ markers. `@CERT_SANS@` is a LIST, so it
# is handled separately (`r` inserts the file after the line, `d` deletes the marker).
render() {
  local tpl="$1" dest="$2" node_name="$3" node_ip="$4"
  sed -e "s|@NODE_NAME@|${node_name}|g" \
      -e "s|@NODE_IP@|${node_ip}|g" \
      -e "s|@VIP@|${VIP}|g" \
      -e "s|@K8S_VERSION@|${K8S_VERSION}|g" \
      -e "s|@CLUSTER_NAME@|${CLUSTER_NAME}|g" \
      -e "s|@POD_CIDR@|${POD_CIDR}|g" \
      -e "s|@SERVICE_CIDR@|${SERVICE_CIDR}|g" \
      -e "s|@TOKEN@|${TOKEN:-}|g" \
      -e "s|@CA_HASH@|${CA_HASH:-}|g" \
      -e "s|@CERT_KEY@|${CERT_KEY:-}|g" \
      -e "/@CERT_SANS@/r ${OUT}/certsans.txt" \
      -e "/@CERT_SANS@/d" \
      "$tpl" >"$dest"
}

# ============================================================================
log "[1/5] Rendering the kubeadm configuration (${OUT}/)"

# certSANs: everything the apiserver can legitimately be reached through. They have to be
# set NOW — a forgotten SAN can only be added by regenerating the certificates. We put ALL
# the possible control-plane IPs in there, including those of nodes not yet created, so
# that growing the cluster later requires no regeneration.
{
  echo "    - ${VIP}"
  echo "    - kubernetes-api"
  for ((i = 1; i <= 5; i++)); do
    echo "    - ${NETWORK}.$((CP_IP_START + (i - 1) * CP_IP_STEP))"
  done
  for n in "${cp_names[@]}"; do echo "    - ${n}"; done
  echo "    - 127.0.0.1"
  echo "    - localhost"
} >"${OUT}/certsans.txt"

render kubeadm/templates/kubeadm-init.yaml.tpl "${OUT}/kubeadm-init.yaml" \
       "$first_cp" "$first_cp_ip"
echo "    ${OUT}/kubeadm-init.yaml  (${first_cp} @ ${first_cp_ip})"

# ============================================================================
log "[2/5] kubeadm init on ${first_cp}"
# `--skip-phases=addon/kube-proxy` rather than v1beta4's declarative `proxy.disabled`
# field: the flag is proven across every version, and it is the one the Cilium docs use.
# The result is identical.
skip=""
[ "$KUBE_PROXY_REPLACEMENT" = "true" ] && skip="addon/kube-proxy"
on_node "$first_cp" "sudo SKIP_PHASES='${skip}' bash /vagrant/kubeadm/node-init.sh"

[ -f "${OUT}/join.env" ] || { echo "ERROR: ${OUT}/join.env missing — the init failed." >&2; exit 1; }
# shellcheck disable=SC1090
. "${OUT}/join.env"
: "${TOKEN:?join token missing}" "${CA_HASH:?CA hash missing}" "${CERT_KEY:?certificate key missing}"

# --- kubeconfig on the host --------------------------------------------------
# Nothing to copy: node-init.sh wrote admin.conf into the synced folder.
cp -f "${OUT}/admin.conf" "${REPO_DIR}/kubeconfig"
# The `chmod` applied by node-init.sh INSIDE the VM is a no-op: on a vboxsf mount the
# permissions come from the mount's fmode/dmode options, not from the file. So it is HERE,
# on the host side, that the hardening has a real effect. `_out/` stays readable by every
# VM of the lab (it holds the join token and the certificate key) — it is gitignored, but
# it is not a vault.
chmod 0600 "${REPO_DIR}/kubeconfig"
chmod 0700 "${OUT}" 2>/dev/null || true
chmod 0600 "${OUT}/join.env" "${OUT}/admin.conf" 2>/dev/null || true
export KUBECONFIG="${REPO_DIR}/kubeconfig"

# The apiserver must answer THROUGH THE VIP before joining anything: that is the address
# the other nodes will use, and it is the only real test that keepalived is doing its job.
printf '    - waiting for https://%s:6443 ' "$VIP"
deadline=$((SECONDS + WAIT_API))
until kubectl get --raw='/readyz' >/dev/null 2>&1; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    printf ' FAILED (%ss)\n' "$WAIT_API"
    cat >&2 <<EOF
ERROR: the apiserver does not answer on the VIP ${VIP} after ${WAIT_API}s.

  The two causes, by frequency:
    1. keepalived is not carrying the VIP. To check from the host:
         vagrant ssh ${first_cp} -c "ip -4 addr show | grep ${VIP}"
         vagrant ssh ${first_cp} -c "sudo systemctl status keepalived"
    2. the apiserver itself does not start:
         vagrant ssh ${first_cp} -c "sudo crictl ps -a | grep apiserver"
         vagrant ssh ${first_cp} -c "sudo journalctl -u kubelet -n 50"
EOF
    exit 1
  fi
  printf '.' ; sleep 5
done
echo ' OK'

# ============================================================================
if [ "$CONTROL_PLANES" -gt 1 ]; then
log "[3/5] Joining the secondary control planes"
# ONE AT A TIME, and this is structural: every join adds a member to etcd, and etcd only
# accepts one membership change at a time. Run in parallel, the second one fails with a
# fairly obscure quorum error.
for ((i = 2; i <= CONTROL_PLANES; i++)); do
  name="${cp_names[$((i-1))]}" ; ip="${cp_ips[$((i-1))]}"
  render kubeadm/templates/kubeadm-join-cp.yaml.tpl "${OUT}/join-${name}.yaml" "$name" "$ip"
  echo "    - ${name} (${ip})"
  on_node "$name" "sudo NODE_NAME='${name}' bash /vagrant/kubeadm/node-join.sh"
  # No extra wait here, and that is deliberate: `kubeadm join --control-plane` is ALREADY
  # blocking on that point. It adds the etcd member as a `learner`, promotes it, then
  # calls `WaitForClusterAvailable` — it only returns once the etcd cluster is healthy
  # again.
  # (There used to be a `kubectl wait --for=condition=Ready=false` here, meant to "wait
  #  for the etcd member to be seen by the API". It did nothing of the sort: a freshly
  #  joined node is already Ready=False for lack of a CNI, so the condition was satisfied
  #  instantly. A guard that lies is worse than no guard at all.)
done
else
log "[3/5] Single control plane — no CP to join"
fi

# ============================================================================
if [ "$WORKERS" -gt 0 ]; then
log "[4/5] Joining the ${WORKERS} worker(s)"
for ((i = 1; i <= WORKERS; i++)); do
  name="${wk_names[$((i-1))]}" ; ip="${wk_ips[$((i-1))]}"
  render kubeadm/templates/kubeadm-join-worker.yaml.tpl "${OUT}/join-${name}.yaml" "$name" "$ip"
  echo "    - ${name} (${ip})"
  on_node "$name" "sudo NODE_NAME='${name}' bash /vagrant/kubeadm/node-join.sh"
done
else
log "[4/5] WORKERS=0 — no worker to join"
fi

# ============================================================================
log "[5/5] Finalisation"

# --- Control-plane taint -----------------------------------------------------
# `auto`: we only untaint when there is no worker at all, otherwise nothing could be
# scheduled any more. This is the setting that makes WORKERS=0 genuinely usable.
untaint="$(printf '%s' "$UNTAINT_CP" | tr '[:upper:]' '[:lower:]')"
case "$untaint" in
  auto)  [ "$WORKERS" -eq 0 ] && untaint=true || untaint=false ;;
  true|false) ;;
  *) echo "    /!\\ UNTAINT_CP='${UNTAINT_CP}' unknown (auto|true|false) — ignored." >&2 ; untaint=false ;;
esac
if [ "$untaint" = "true" ]; then
  echo "    - removing the control-plane taint (pods will be schedulable there)"
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
fi

# --- Labelling the workers ---------------------------------------------------
# kubeadm sets NO role on a worker: `kubectl get nodes` shows `<none>` in the ROLES
# column, which is confusing and breaks `node-role.kubernetes.io/worker` selectors.
for name in "${wk_names[@]:-}"; do
  [ -z "$name" ] && continue
  kubectl label node "$name" node-role.kubernetes.io/worker= --overwrite >/dev/null 2>&1 || true
done

# --- The cluster's fact sheet, read back by the _k8s/ scripts ----------------
# The host-only interface is DETECTED inside the VM (see provision.sh) rather than
# guessed: Debian 13 uses predictable names (`enp0s8`) but some boxes keep `eth1`, and
# Cilium needs the real name for its L2 announcement.
# `|| true` is INDISPENSABLE: an assignment whose command substitution fails triggers
# `set -e`, and the fallback line below would never be reached. The cluster would then be
# up but `_out/cluster.env` never written — every _k8s/ script would fall back to `eth1`
# instead of the real interface, Cilium would announce over L2 on the wrong NIC, and no UI
# would be reachable. The silent failure par excellence.
hostonly_if="$(on_node "$first_cp" "sed -n 's/^HOSTONLY_IF=//p' /etc/kubeadm-lab/node.env" 2>/dev/null \
                | tr -d '[:space:]' || true)"
hostonly_if="${hostonly_if:-eth1}"
cat >"${OUT}/cluster.env" <<EOF
# Generated by kubeadm/cluster-up.sh — read back by the _k8s/*-up.sh scripts.
CLUSTER_NAME=${CLUSTER_NAME}
K8S_VERSION=${K8S_VERSION}
VIP=${VIP}
API_ENDPOINT=${VIP}:6443
POD_CIDR=${POD_CIDR}
SERVICE_CIDR=${SERVICE_CIDR}
CNI=${CNI}
KUBE_PROXY_REPLACEMENT=${KUBE_PROXY_REPLACEMENT}
HOSTONLY_IF=${hostonly_if}
CONTROL_PLANES=${CONTROL_PLANES}
WORKERS=${WORKERS}
EOF
echo "    - ${OUT}/cluster.env (host-only interface detected: ${hostonly_if})"

# ============================================================================
echo
echo "================================================================"
echo " Cluster ready."
echo "   export KUBECONFIG=${REPO_DIR}/kubeconfig"
echo "   kubectl get nodes -o wide"
echo "================================================================"
kubectl get nodes -o wide 2>/dev/null || true
echo
if [ "$CNI" = "none" ]; then
  echo " CNI=none: the nodes will stay NotReady until YOU lay down a CNI."
else
  echo " The nodes are NotReady: this is NORMAL, no CNI is installed yet."
  echo " Next step — the application layer (CNI ${CNI}, Gateway, metrics, TLS):"
  echo "     ./_k8s/platform-up.sh"
fi
