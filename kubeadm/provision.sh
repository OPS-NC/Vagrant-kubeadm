#!/usr/bin/env bash
#
# provision.sh — system preparation of a node, run INSIDE the VM by Vagrant
# (see `node.vm.provision "shell"` in the Vagrantfile). Bootstraps NO cluster:
# at the end of `vagrant up`, every VM is ready to receive a `kubeadm init/join`,
# and nothing more. The bootstrap is driven from the host by kubeadm/cluster-up.sh.
#
# What this script lays down, in order (each step assumes the previous one):
#   1. /etc/hosts        deterministic resolution of every node of the lab
#   2. system upgrade    non-interactive apt upgrade, GRUB preseeded (see step 2)
#   3. kernel prereqs    swap off, modules, sysctl
#   4. base packages     including open-iscsi/nfs-common (Longhorn) and conntrack (kube-proxy)
#   5. containerd        2.x (Docker repo) or 1.7 (Debian), systemd cgroup
#   6. kubeadm/kubelet/kubectl  pinned version then `apt-mark hold`
#   7. images            pre-pulled, so that `kubeadm init` downloads nothing
#   8. keepalived        API VIP over VRRP — control planes only
#
# Idempotent: re-runnable at will (`vagrant provision`).
#
# ⚠️ `vagrant provision` IS NOT a Kubernetes upgrade path: step 6 reinstalls
#    K8S_VERSION on ALL nodes at once, without ever calling `kubeadm upgrade`.
#    Bumping lab.env then re-provisioning would put every kubelet one minor ahead of
#    the apiserver. See kubeadm/UPGRADE.md.
#
# Variables received from the Vagrantfile: NODE_NAME NODE_ROLE NODE_INDEX NODE_IP NETWORK
# VIP CP_IPS CP_IP_START CP_IP_STEP VRRP_ROUTER_ID K8S_VERSION K8S_APT_MINOR CONTAINERD_SOURCE
# REGISTRY_MIRROR HOSTS_ENTRIES SYSTEM_UPGRADE KUBE_PROXY_REPLACEMENT
set -euo pipefail

# --- Non-interactivity: belt AND braces --------------------------------------
# A Vagrant provisioner has NO terminal. So the slightest debconf question shows up
# nowhere: it blocks `vagrant up` until the timeout, without the faintest hint of what
# is expected. The three settings are not redundant:
#   DEBIAN_FRONTEND=noninteractive  debconf stops asking and takes the default
#   DEBIAN_PRIORITY=critical        even "high priority" questions are skipped
#   NEEDRESTART_MODE=a              needrestart restarts services without asking
#                                   (it is pulled in by several packages on Debian 13 and
#                                   its list of services to restart is a prompt)
export DEBIAN_FRONTEND=noninteractive
export DEBIAN_PRIORITY=critical
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

NODE_NAME="${NODE_NAME:-$(hostname)}"
NODE_ROLE="${NODE_ROLE:-worker}"
NODE_INDEX="${NODE_INDEX:-1}"
NODE_IP="${NODE_IP:?NODE_IP missing (provided by the Vagrantfile)}"
NETWORK="${NETWORK:-192.168.56}"
VIP="${VIP:-${NETWORK}.5}"
CP_IPS="${CP_IPS:-}"
CP_IP_START="${CP_IP_START:-10}"
CP_IP_STEP="${CP_IP_STEP:-10}"
VRRP_ROUTER_ID="${VRRP_ROUTER_ID:-51}"
K8S_VERSION="${K8S_VERSION:-1.36.3}"
K8S_APT_MINOR="${K8S_APT_MINOR:-v1.36}"
CONTAINERD_SOURCE="${CONTAINERD_SOURCE:-docker}"
REGISTRY_MIRROR="${REGISTRY_MIRROR:-}"
HOSTS_ENTRIES="${HOSTS_ENTRIES:-}"
SYSTEM_UPGRADE="${SYSTEM_UPGRADE:-true}"
KUBE_PROXY_REPLACEMENT="${KUBE_PROXY_REPLACEMENT:-true}"

# Normalisation + REJECTION of the unknown, like SELF_SIGNED and UNTAINT_CP elsewhere in
# the repo. Without this `case`, `SYSTEM_UPGRADE=True` or `yes` would SILENTLY skip the
# upgrade — and a typo (`flase`) would do the same, without a word.
for v in SYSTEM_UPGRADE KUBE_PROXY_REPLACEMENT; do
  eval "val=\${$v}"
  val="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
  case "$val" in
    true|false) eval "$v=\$val" ;;
    *) echo "ERROR: ${v}='${val}' unknown (true|false)." >&2 ; exit 1 ;;
  esac
done

log() { printf '\n\033[1;36m[%s] ==> %s\033[0m\n' "$NODE_NAME" "$*"; }

# ============================================================================
log "[1/8] Name resolution (/etc/hosts)"
# A delimited block, rewritten on every pass: re-running `vagrant provision` must not
# stack the same lines ten times over.
if [ -n "$HOSTS_ENTRIES" ]; then
  sed -i '/# >>> vagrant-kubeadm/,/# <<< vagrant-kubeadm/d' /etc/hosts
  {
    echo "# >>> vagrant-kubeadm"
    echo "$HOSTS_ENTRIES"
    echo "${VIP}  kubernetes-api ${NODE_NAME%%-*}-api"
    echo "# <<< vagrant-kubeadm"
  } >>/etc/hosts
fi
# Debian maps the hostname onto 127.0.1.1. The kubelet resolves its own name to
# register itself: left in place, the node advertises a loopback address and becomes
# unreachable from the other nodes.
sed -i "/^127\.0\.1\.1\s\+${NODE_NAME}\b/d" /etc/hosts

# ============================================================================
if [ "$SYSTEM_UPGRADE" = "true" ]; then
log "[2/8] System upgrade (non-interactive, GRUB preseeded)"

# --- THE TRAP: grub-pc and its debconf question -------------------------------
# `apt-get upgrade` on a Debian box sooner or later upgrades `grub-pc`. Its postinst then
# asks a debconf question `grub-pc/install_devices` — "on which disk(s) should GRUB be
# installed?" — because the answer cannot be deduced: GRUB has to be written into the MBR
# of a physical disk, and the package cannot guess it.
#
# In a Vagrant provisioner there is NO terminal: the question shows up nowhere and
# `vagrant up` stays blocked until the timeout. Worse, if it is skipped without an answer,
# GRUB is not rewritten into the MBR and the VM may fail to boot at the next reboot — a
# failure that shows up long after provisioning, hence very far from its cause.
#
# So we preseed the answer BEFORE any upgrade. `debconf-set-selections` is what puts the
# answer into the debconf database; the postinst reads it instead of asking.

# The disk is not hard-coded: we walk up from the root filesystem to the parent disk.
# `/dev/sda` is the usual VirtualBox case, but it is only a fallback — a different
# provider (libvirt -> /dev/vda) or an unexpected controller order would give another
# name, and a wrong value here is exactly what we want to avoid.
root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
boot_disk=""
if [ -n "$root_src" ]; then
  parent="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
  [ -n "$parent" ] && boot_disk="/dev/${parent}"
fi
boot_disk="${boot_disk:-/dev/sda}"

if [ -d /sys/firmware/efi ]; then
  # Under UEFI it is `grub-efi` that is installed: it writes into the ESP partition and
  # never asks `install_devices`. We preseed anyway — no effect here, but correct if the
  # box ever switches to BIOS.
  echo "    UEFI boot detected (grub-efi) — no install_devices question"
else
  echo "    BIOS boot — GRUB will be installed on ${boot_disk}"
fi

debconf-set-selections <<EOF
grub-pc grub-pc/install_devices multiselect ${boot_disk}
grub-pc grub-pc/install_devices_disks_changed multiselect ${boot_disk}
grub-pc grub-pc/install_devices_empty boolean false
grub-pc grub-pc/postrm_purge_boot_grub boolean false
EOF

apt-get update -qq

# `upgrade` and definitely NOT `full-upgrade`/`dist-upgrade`: `upgrade` cannot install a
# package under a new name, so it deliberately leaves kernel bumps aside
# (linux-image-6.12.x is a NEW package name). That is exactly what we want: we upgrade the
# system without changing the kernel under the feet of the modules loaded in the next step
# (br_netfilter, iscsi_tcp), and without forcing a reboot.
#
# --force-confdef + --force-confold: keep the configuration files in place without asking
# "keep the installed version or the maintainer's one?".
apt-get -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  upgrade

apt-get -y -qq autoremove
else
log "[2/8] System upgrade — skipped (SYSTEM_UPGRADE=${SYSTEM_UPGRADE})"
apt-get update -qq
fi

# ============================================================================
log "[3/8] Kernel prerequisites (swap, modules, sysctl)"

# --- swap ---
# NodeSwap has been GA since 1.34, but `failSwapOn` STILL defaults to true: the kubelet
# refuses to start with swap enabled until it is configured explicitly. On a lab we turn
# it off — the shortest and best-tested path.
swapoff -a
sed -ri 's/^\s*([^#].*\s+swap\s+)/#\1/' /etc/fstab
# Debian 13 may provide swap through a systemd unit (zram, swapfile) that /etc/fstab does
# not describe: masking it prevents it from coming back at reboot.
# `|| true` on the WHOLE pipeline: with no swap unit, systemctl exits 1 and, under
# `set -e` + `pipefail`, would kill the node preparation as early as step 2.
{ systemctl list-unit-files --type=swap --no-legend 2>/dev/null || true; } \
  | awk '{print $1}' | while read -r unit; do
      [ -n "$unit" ] && systemctl mask "$unit" >/dev/null 2>&1 || true
    done

# --- modules ---
# `overlay` is loaded by containerd's snapshotter anyway, and Cilium in eBPF mode does not
# need `br_netfilter`. We load them regardless: they are indispensable as soon as one
# switches to calico/flannel (iptables datapath), and the lab must stay usable with all
# four CNI values.
tee /etc/modules-load.d/k8s.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay    || true
modprobe br_netfilter || true
# iSCSI: required by Longhorn (_k8s/longhorn/). Without it the CSI pods loop forever.
tee /etc/modules-load.d/iscsi.conf >/dev/null <<'EOF'
iscsi_tcp
EOF
modprobe iscsi_tcp || true

# --- sysctl ---
# Upstream docs now only require `ip_forward` and delegate the rest to the CNI. The
# `bridge-nf-call-*` keys stay necessary for iptables datapaths (calico/flannel).
# `rp_filter=0`: reverse path filtering breaks pod traffic on several CNIs.
tee /etc/sysctl.d/99-kubernetes.conf >/dev/null <<'EOF'
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.conf.all.rp_filter         = 0
net.ipv4.conf.default.rp_filter     = 0
EOF
sysctl --system >/dev/null

# ============================================================================
log "[4/8] Base packages"
# No `apt-get update` here: step 2 just did it, in both branches (with or without the
# system upgrade). Doing it again would only cost boot time.
# conntrack + socat + ethtool: required by the kubeadm preflight and by kube-proxy.
# open-iscsi + nfs-common: Longhorn prerequisites (_k8s/longhorn/).
# On Talos those two came through a system extension baked into the image;
# on Debian it is a plain package — that is the whole difference in model.
apt-get install -y -qq \
  apt-transport-https ca-certificates curl gnupg gpg \
  conntrack socat ethtool iptables jq \
  open-iscsi nfs-common
install -m 0755 -d /etc/apt/keyrings

# keepalived ONLY on the control planes: the Debian package enables its unit at install
# time, and on a worker — which will never have a keepalived.conf — it would fail in a
# loop, polluting the journals for nothing.
if [ "$NODE_ROLE" = "controlplane" ]; then
  apt-get install -y -qq keepalived
fi

# iscsid must run AND start at boot for Longhorn.
systemctl enable --now iscsid >/dev/null 2>&1 || true

# ============================================================================
log "[5/8] containerd (source: ${CONTAINERD_SOURCE})"
case "$CONTAINERD_SOURCE" in
  docker)
    # containerd 2.x. Only the 2.x branch implements the CRI `RuntimeConfig` method that
    # kubeadm uses to read the runtime's cgroup driver. On 1.36 its absence is only a
    # preflight warning, but the fallback disappears in 1.37: Debian's 1.7 branch is a
    # dead end (containerd#11346 closed without a merge).
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
      curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
    fi
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      >/etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq containerd.io
    ;;
  debian)
    apt-get install -y -qq containerd containernetworking-plugins
    ;;
  *)
    echo "ERROR: CONTAINERD_SOURCE='${CONTAINERD_SOURCE}' unknown (docker|debian)." >&2
    exit 1
    ;;
esac

# ============================================================================
log "[6/8] kubelet / kubeadm / kubectl ${K8S_VERSION} (repo ${K8S_APT_MINOR})"
# kubernetes.io only publishes the classic `.list` form (no deb822): that is the one
# tested upstream, so we do not deviate from it.
if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_APT_MINOR}/deb/Release.key" \
    | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/${K8S_APT_MINOR}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update -qq

# The Debian revision suffix is not always `-1.1` (1.36.2 was republished as `-2.1`): so
# we ask for `<version>-*` rather than a guessed suffix. The `hold` is lifted for the
# duration of the install, otherwise a reinstall would be ignored.
apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
apt-get install -y -qq --allow-change-held-packages \
  "kubelet=${K8S_VERSION}-*" "kubeadm=${K8S_VERSION}-*" "kubectl=${K8S_VERSION}-*"
# `hold`: an upgrade must be a DELIBERATE act (see kubeadm/UPGRADE.md), never the side
# effect of an `apt upgrade` that would break the kubelet/apiserver skew.
apt-mark hold kubelet kubeadm kubectl >/dev/null
systemctl enable kubelet >/dev/null 2>&1 || true

# --- containerd configuration, now that kubeadm can tell us which pause to use ---
# We ASK kubeadm instead of hard-coding the version: the `pause` tag changes with every
# minor, and a mismatch between containerd's and the one kubeadm expects pre-pulls one
# image and uses another (invisible online, fatal offline).
PAUSE_IMAGE="$(kubeadm config images list --kubernetes-version "v${K8S_VERSION}" 2>/dev/null \
                | grep -m1 '/pause:' || true)"
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.10.2}"

mkdir -p /etc/containerd
# Config regenerated on every pass: the file's version (v2 on containerd 1.7, v3 on 2.x)
# must follow the binary actually installed, not an older file.
containerd config default >/etc/containerd/config.toml

# `SystemdCgroup`: Debian 13 runs cgroup v2 with systemd as the manager. If containerd
# stays on `cgroupfs`, two managers fight over the same hierarchy and the nodes become
# unstable under load. The key name is identical in v2 and v3, a single `sed` covers both.
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# The `pause` image. The key changed name AND location between the two formats:
#   v2 (containerd 1.7): sandbox_image = "..."  under [plugins."io.containerd.grpc.v1.cri"]
#   v3 (containerd 2.x): sandbox = '...'        under [plugins.'io.containerd.cri.v1.images'.pinned_images]
# This is THE trap of the 1.7 -> 2.x migration: a config copied as-is silently loses the
# setting.
if grep -q '^[[:space:]]*sandbox_image[[:space:]]*=' /etc/containerd/config.toml; then
  sed -i "s#^\([[:space:]]*sandbox_image[[:space:]]*=[[:space:]]*\).*#\1\"${PAUSE_IMAGE}\"#" \
    /etc/containerd/config.toml
fi
if grep -q "^[[:space:]]*sandbox[[:space:]]*=" /etc/containerd/config.toml; then
  sed -i "s#^\([[:space:]]*sandbox[[:space:]]*=[[:space:]]*\).*#\1'${PAUSE_IMAGE}'#" \
    /etc/containerd/config.toml
fi

# Registry mirror (pull-through proxy). `config_path` is the only setting left empty in
# the generated config, in v2 as in v3: we fill it without depending on the plugin name,
# which was renamed between the two formats.
if [ -n "$REGISTRY_MIRROR" ]; then
  sed -i "s#^\([[:space:]]*config_path[[:space:]]*=[[:space:]]*\)\(\"\"\|''\)#\1\"/etc/containerd/certs.d\"#" \
    /etc/containerd/config.toml
  mkdir -p /etc/containerd/certs.d/docker.io
  # `override_path`: the mirror is exposed under a sub-path, which has to be treated as
  # the base of the registry API (otherwise containerd appends a second /v2 to it).
  tee /etc/containerd/certs.d/docker.io/hosts.toml >/dev/null <<EOF
server = "https://registry-1.docker.io"

[host."${REGISTRY_MIRROR}"]
  capabilities = ["pull", "resolve"]
  override_path = true
EOF
fi

systemctl daemon-reload
systemctl enable containerd >/dev/null 2>&1 || true
systemctl restart containerd

# crictl talks to the same socket as the kubelet. Without this file, `crictl` goes looking
# for dockershim and prints confusing errors during diagnostics.
tee /etc/crictl.yaml >/dev/null <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

# ============================================================================
log "[7/8] Pre-pulling the images"
# Done here, DURING `vagrant up`, hence in parallel on every VM. `kubeadm init` then has
# nothing left to download, which removes the biggest source of bootstrap timeouts (and
# makes the lab rebuildable offline).
if [ "$NODE_ROLE" = "controlplane" ]; then
  kubeadm config images pull --kubernetes-version "v${K8S_VERSION}" >/dev/null 2>&1 \
    || echo "    (partial pre-pull — kubeadm init will re-download as needed)"
else
  # A worker hosts neither apiserver, nor etcd, nor scheduler: pulling the 7 images would
  # waste ~500 MiB per worker. `pause` is still useful to it; `kube-proxy` only if it is
  # really installed — with KUBE_PROXY_REPLACEMENT=true (the repo default) cluster-up.sh
  # skips `addon/kube-proxy` and the image would NEVER be used.
  images="$PAUSE_IMAGE"
  [ "$KUBE_PROXY_REPLACEMENT" != "true" ] && images="$images registry.k8s.io/kube-proxy:v${K8S_VERSION}"
  for img in $images; do
    crictl pull "$img" >/dev/null 2>&1 || true
  done
fi

# ============================================================================
# Host-only interface detection. NEVER a hard-coded name: Debian 13 uses predictable
# names (`enp0s8`), but some boxes still expose `eth1`. We look for the interface that
# CARRIES the node's IP — infallible and independent of the naming scheme.
HOSTONLY_IF="$(ip -o -4 addr show 2>/dev/null \
                | awk -v pfx="${NODE_IP}/" '$4 ~ ("^" pfx) {print $2; exit}')"
if [ -z "$HOSTONLY_IF" ]; then
  HOSTONLY_IF="$(ip -o -4 route show 2>/dev/null \
                  | awk -v n="${NETWORK}.0/24" '$1 == n {print $3; exit}')"
fi
HOSTONLY_IF="${HOSTONLY_IF:-eth1}"

# The node's fact sheet, read back by cluster-up.sh (through `vagrant ssh`) and by the
# _k8s/ scripts that need the interface name (Cilium's L2 announcement).
mkdir -p /etc/kubeadm-lab
tee /etc/kubeadm-lab/node.env >/dev/null <<EOF
NODE_NAME=${NODE_NAME}
NODE_ROLE=${NODE_ROLE}
NODE_INDEX=${NODE_INDEX}
NODE_IP=${NODE_IP}
HOSTONLY_IF=${HOSTONLY_IF}
VIP=${VIP}
K8S_VERSION=${K8S_VERSION}
EOF

# ============================================================================
if [ "$NODE_ROLE" = "controlplane" ]; then
log "[8/8] keepalived — VIP ${VIP} on ${HOSTONLY_IF} (VRRP)"

# WHY keepalived rather than kube-vip.
#   The VIP must exist BEFORE `kubeadm init`, since `controlPlaneEndpoint` points at it.
#   kube-vip runs as a static pod and does its leader election through the Kubernetes
#   API — that is, through the very VIP it is supposed to carry: a chicken-and-egg
#   problem only solved with the `super-admin.conf` hack, itself fragile since k8s 1.29
#   moved `admin.conf` out of `system:masters`.
#   keepalived, on the other hand, is a VRRP daemon: it knows nothing about Kubernetes,
#   sets the VIP as soon as the VM boots, and the bootstrap has no circular dependency
#   left. kube-vip stays a valid alternative once the cluster is up (see README).

# VRRP in UNICAST and not multicast: on VirtualBox's host-only virtual switch, multicast
# is the first thing to start behaving strangely.
#
# ⚠️ THE PEERS ARE THE *POSSIBLE* CONTROL PLANES, NOT THE ONES THAT EXIST TODAY.
#    That is what makes growing 1 CP -> 3 CP safe, and it is not a detail.
#
#    The trap, if one is not careful: with CONTROL_PLANES=1, the peer list would be EMPTY
#    and the `unicast_peer` block absent. Now keepalived, faced with a `unicast_src_ip`
#    without a single peer, does NOT refuse the configuration: it emits a
#    CONFIG_DEPRECATED and SILENTLY FALLS BACK TO MULTICAST.
#    Switching later to CONTROL_PLANES=3 does NOT re-provision cp1 (Vagrant only replays
#    provisioners on brand-new VMs, unless `--provision`): so cp1 stays in multicast while
#    cp2/cp3 start in real unicast. And the two modes are MUTUALLY DEAF — a socket bound
#    to the multicast address does not receive unicast, and vice versa. cp1 believes it is
#    alone and takes the VIP; cp2 believes it is alone too and takes it as well. TWO nodes
#    then carry 192.168.56.5: ARP race, intermittent API, and since admin.conf,
#    kubelet.conf AND Cilium's k8sServiceHost all point at the VIP, the whole cluster
#    wobbles.
#
#    By listing up front the 5 CP IPs the addressing scheme plans for (the same ones as
#    cluster-up.sh's certSANs), cp1's configuration is already the right one the day cp2
#    and cp3 show up. A peer that does not exist yet only costs one unanswered VRRP packet
#    per second.
peers=""
for i in 1 2 3 4 5; do
  ip="${NETWORK}.$((CP_IP_START + (i - 1) * CP_IP_STEP))"
  [ "$ip" = "$NODE_IP" ] && continue
  peers="${peers}        ${ip}"$'\n'
done

# cp1 = 100, cp2 = 90, cp3 = 80. The health script subtracts 30: a cp1 whose apiserver is
# dead drops to 70 and falls BEHIND a healthy cp2 (90), which takes the VIP over.
priority=$((100 - (NODE_INDEX - 1) * 10))
[ "$priority" -lt 10 ] && priority=10

# The VIP must only live where the LOCAL apiserver answers. The endpoint is reachable
# anonymously: the `system:public-info-viewer` ClusterRoleBinding, laid down by kubeadm,
# opens /healthz, /livez and /readyz to `system:unauthenticated`. So there is no
# credential to hand to the health script.
#
# ⚠️ `/livez/ping` and NOT `/livez`. Contrary to a common belief, `/livez` AGGREGATES
#    every registered check — including `etcd`. And `kubeadm join --control-plane` makes
#    etcd temporarily unavailable while going from 1 to 2 members (kubeadm documents this
#    itself). A global `/livez` failing for more than `fall x interval` = 9 s would drop
#    cp1 to 70 while cp2 has just reached 90: THE VIP WOULD JUMP TO CP2 IN THE MIDDLE OF
#    THE BOOTSTRAP. `/livez/ping` is the trivial sub-check "the process answers", with no
#    dependency on any backend: exactly what we want to know to decide who carries the VIP.
#
# As long as the cluster does not exist, the test fails on ALL control planes: they each
# lose 30 points, the relative order is preserved, and the VIP is carried anyway. That is
# exactly what is needed for `kubeadm init` to find it in place.
#
# The script lives in /etc/keepalived and NOT in /usr/local/bin: with
# `enable_script_security`, keepalived inspects EVERY component of the path and plainly
# disables the track_script if a directory is group-writable with a non-root group. And
# /usr/local/bin becomes `root:staff 2775` as soon as /etc/staff-group-for-usr-local
# exists (the case of a system migrated from stretch). VIP failover would then be DEAD,
# with no other trace than a line in journalctl. /etc/keepalived is root:root by
# construction: the risk disappears.
tee /etc/keepalived/check-apiserver.sh >/dev/null <<'EOF'
#!/bin/sh
curl -sfk --max-time 2 https://127.0.0.1:6443/livez/ping >/dev/null
EOF
chown root:root /etc/keepalived/check-apiserver.sh
chmod 0755 /etc/keepalived/check-apiserver.sh

# No `authentication` block: VRRPv2 authentication sends a password in the clear and
# brings no real security. Here the trust boundary is the host-only network itself. To
# coexist with ANOTHER keepalived lab on the same network, VRRP_ROUTER_ID (lab.env) is
# what has to change, not a password.
tee /etc/keepalived/keepalived.conf >/dev/null <<EOF
global_defs {
    enable_script_security
    script_user root
}

vrrp_script chk_apiserver {
    script "/etc/keepalived/check-apiserver.sh"
    interval 3
    timeout 2
    fall 3
    rise 2
    weight -30
}

vrrp_instance VI_K8S {
    state BACKUP
    interface ${HOSTONLY_IF}
    virtual_router_id ${VRRP_ROUTER_ID}
    priority ${priority}
    advert_int 1
    unicast_src_ip ${NODE_IP}
$([ -n "$peers" ] && printf '    unicast_peer {\n%s    }\n' "$peers")
    virtual_ipaddress {
        ${VIP}/24
    }
    track_script {
        chk_apiserver
    }
}
EOF

systemctl enable keepalived >/dev/null 2>&1 || true
systemctl restart keepalived
else
log "[8/8] keepalived — skipped (node with role '${NODE_ROLE}')"
fi

# ============================================================================
log "Node ready for kubeadm."
echo "    role       : ${NODE_ROLE}"
echo "    node IP    : ${NODE_IP}  (interface ${HOSTONLY_IF})"
echo "    kubeadm    : $(kubeadm version -o short 2>/dev/null || echo '?')"
echo "    containerd : $(containerd --version 2>/dev/null | awk '{print $3}' || echo '?')"
