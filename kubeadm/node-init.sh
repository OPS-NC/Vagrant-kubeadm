#!/usr/bin/env bash
#
# node-init.sh — `kubeadm init` on the FIRST control plane. Run INSIDE the VM,
# called by kubeadm/cluster-up.sh from the host:
#     vagrant ssh k8s-cp1 -c "sudo bash /vagrant/kubeadm/node-init.sh"
#
# The logic lives here, in a versioned file, rather than in a long command passed to
# `vagrant ssh -c`: it is readable, it can be reviewed in a diff, and above all it avoids
# the quoting hell of escaping through two layers of shell.
#
# Reads : /vagrant/_out/kubeadm-init.yaml   (rendered by cluster-up.sh)
# Writes: /vagrant/_out/admin.conf          (kubeconfig, picked up by the host)
#         /vagrant/_out/join.env            (token, CA hash, certificate key)
#
# Idempotent: if the control plane is ALREADY initialised, we do not re-run `init`
# (that would be destructive) — we only regenerate the join material.
set -euo pipefail

OUT="/vagrant/_out"
CONFIG="${OUT}/kubeadm-init.yaml"
SKIP_PHASES="${SKIP_PHASES:-}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

[ -f "$CONFIG" ] || { echo "ERROR: ${CONFIG} not found (cluster-up.sh must render it first)." >&2; exit 1; }

# ============================================================================
if [ -f /etc/kubernetes/admin.conf ]; then
  log 'Control plane ALREADY initialised — kubeadm init not re-run'
  echo "    Re-running it on a live cluster would destroy it. To start from scratch:"
  echo "      ./kubeadm/cluster-reset.sh    (or vagrant destroy -f && vagrant up)"
else
  log "kubeadm init${SKIP_PHASES:+ (skipped phases: ${SKIP_PHASES})}"
  # `--upload-certs`: puts the cluster CAs into the `kubeadm-certs` Secret, encrypted with
  # the certificate key. That is what lets the other control planes join without copying
  # /etc/kubernetes/pki by hand.
  kubeadm init \
    --config "$CONFIG" \
    --upload-certs \
    ${SKIP_PHASES:+--skip-phases="$SKIP_PHASES"}
fi

# ============================================================================
log "kubeconfig for root and for the vagrant user"
install -o root -g root -m 0600 -D /etc/kubernetes/admin.conf /root/.kube/config
install -d -o vagrant -g vagrant -m 0700 /home/vagrant/.kube
install -o vagrant -g vagrant -m 0600 /etc/kubernetes/admin.conf /home/vagrant/.kube/config

# ============================================================================
log "Join material (token, CA hash, certificate key)"
# The token created by `init` expires in 24 h and the certificate key in 2 h. So we always
# regenerate them: cluster-up.sh may be re-run long after the `init` (typically to add a
# node), and an expired piece of material produces a particularly opaque join error.
join_cmd="$(kubeadm token create --print-join-command)"
# Expected shape:
#   kubeadm join <ip>:6443 --token <t> --discovery-token-ca-cert-hash sha256:<h>
token="$(printf '%s\n' "$join_cmd" | sed -n 's/.*--token \([^ ]*\).*/\1/p')"
ca_hash="$(printf '%s\n' "$join_cmd" | sed -n 's/.*--discovery-token-ca-cert-hash sha256:\([^ ]*\).*/\1/p')"

# `upload-certs` re-encrypts the kubeadm-certs Secret and prints the new key on its last
# line. Safe to replay on a running cluster.
# ⚠️ `--config` IS MANDATORY HERE, and its absence is a formidable trap.
#
#    This phase builds its Kubernetes client from
#    `InitConfiguration.LocalAPIEndpoint.AdvertiseAddress` (and NOT from
#    `controlPlaneEndpoint`, nor from admin.conf):
#        d.client = EnsureAdminClusterRoleBinding(..., &d.Cfg().LocalAPIEndpoint, nil)
#    Without `--config`, kubeadm applies its defaults and DETECTS that address from the
#    default route — which, in a Vagrant lab, goes out through the NAT NIC: 10.0.2.15,
#    the SAME on every VM. The client then hits https://10.0.2.15:6443 and the TLS
#    handshake fails, since that is obviously not in the certSANs:
#        x509: certificate is valid for 192.168.56.10, 192.168.56.5, …, not 10.0.2.15
#
#    This is exactly the `node-ip` trap documented in the README, in another guise.
#    Adding 10.0.2.15 to the certSANs would be the WRONG fix: that address is shared by
#    every VM, it identifies no node. On the contrary, kubeadm has to be told what its
#    real local endpoint is — which is what `--config` does.
#
#    `--upload-certs` is indeed one of the few flags combinable with `--config`
#    (see isAllowedFlag); `--certificate-key` is not — we do not use it.
#
# We extract the key by its SHAPE (64 hexadecimal characters) rather than by its position:
# `tail -n1` would break on the first message a future kubeadm version appends at the end
# of the phase, and the error would be very hard to relate to its cause.
# `|| true`: with no match, `grep` returns 1 and, under `pipefail`, would kill the script
# BEFORE the explicit check that follows — which produces a much better message.
cert_key="$(kubeadm init phase upload-certs --upload-certs --config "$CONFIG" \
             | grep -Eo '^[a-f0-9]{64}$' | tail -n1 || true)"

if [ -z "$token" ] || [ -z "$ca_hash" ] || [ -z "$cert_key" ]; then
  # We name the missing piece: the three come from DIFFERENT commands, and knowing which
  # one failed points the diagnosis immediately. The previous message only printed
  # `join_cmd`, which suggested a token problem when it was `upload-certs` failing.
  {
    echo "ERROR: unable to extract the join material."
    [ -z "$token" ]    && echo "  - token           MISSING   (kubeadm token create --print-join-command)"
    [ -z "$ca_hash" ]  && echo "  - CA hash         MISSING   (same)"
    [ -z "$cert_key" ] && echo "  - certificate key MISSING   (kubeadm init phase upload-certs)"
    echo
    echo "  join_cmd = ${join_cmd:-<empty>}"
    echo
    echo "  If the error above mentions \"x509: certificate is valid for … not 10.0.2.15\","
    echo "  kubeadm aimed at the shared NAT NIC instead of the node's host-only IP."
    echo "  This version passes --config to avoid that: check that ${CONFIG} really exists."
  } >&2
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

log "Control plane initialised."
echo "    The nodes will stay NotReady until a CNI is laid down — this is NORMAL."
