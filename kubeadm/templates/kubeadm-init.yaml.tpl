# `kubeadm init` configuration template — rendered into _out/kubeadm-init.yaml by
# kubeadm/cluster-up.sh (substitution of the @NAME@ markers).
#
# API `kubeadm.k8s.io/v1beta4`: this is the current version, and the default one since
# Kubernetes 1.31. `v1beta3` is deprecated.
#
# ⚠️ THE v1beta3 -> v1beta4 MIGRATION TRAP: `extraArgs` and `kubeletExtraArgs` are NO
#    LONGER dictionaries but LISTS of {name, value} — the change was made to allow the
#    same flag several times. So any file written before 1.31 is invalid as-is, and the
#    error returned is not explicit.
#      v1beta3:  extraArgs: {bind-address: "0.0.0.0"}
#      v1beta4:  extraArgs: [{name: bind-address, value: "0.0.0.0"}]

apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  # The REAL IP of this node, definitely not the VIP: this is the address THIS apiserver
  # listens on. The VIP is the shared `controlPlaneEndpoint` (further down).
  advertiseAddress: "@NODE_IP@"
  bindPort: 6443
nodeRegistration:
  name: "@NODE_NAME@"
  criSocket: unix:///run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  kubeletExtraArgs:
    # ⚠️ THE number one trap of a Vagrant lab. Every VM has a NAT NIC eth0 at
    #    10.0.2.15 — THE SAME on every VM. Without `node-ip`, the kubelet picks that
    #    default route and ALL the nodes register with the same address:
    #    `kubectl get nodes -o wide` looks correct, but the logs, `kubectl exec`, the
    #    probes and cross-node traffic all go to the wrong place.
    - name: node-ip
      value: "@NODE_IP@"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v@K8S_VERSION@
clusterName: @CLUSTER_NAME@

# `controlPlaneEndpoint` is frozen into the certificates and into every kubeconfig at
# `init` time. We put the keepalived VIP in there EVEN with a single control plane: that is
# what makes it possible to add a CP later through a plain `join`, without regenerating the
# certificates nor redistributing the kubeconfigs.
controlPlaneEndpoint: "@VIP@:6443"

networking:
  # ⚠️ This CIDR must be the one the CNI really announces. Cilium in cluster-pool mode
  #    defaults to 10.0.0.0/8, unrelated to whatever is declared here:
  #    _k8s/cilium/cilium-up.sh therefore passes POD_CIDR to it explicitly.
  podSubnet: "@POD_CIDR@"
  serviceSubnet: "@SERVICE_CIDR@"
  dnsDomain: cluster.local

etcd:
  local:
    # Stacked etcd (on the control planes): this is the kubeadm default and the right call
    # for a lab. It is very sensitive to fsync latency — hence the value of keeping the
    # VM disks on an SSD (see TROUBLESHOOTING.md).
    dataDir: /var/lib/etcd
    extraArgs:
      # kubeadm only exposes etcd's metrics on loopback
      # (`--listen-metrics-urls=http://127.0.0.1:2381`), because by default that endpoint
      # only serves the static pod's liveness probe. Prometheus, however, scrapes from a
      # pod: it cannot reach the node's loopback, and kube-prometheus-stack's `kubeEtcd`
      # target stays DOWN with no explanation.
      # `0.0.0.0` also covers `127.0.0.1`, so the probe keeps working.
      # Acceptable here because the host-only network is isolated — this port requires NO
      # authentication at all and must never be exposed on a real network.
      - name: listen-metrics-urls
        value: "http://0.0.0.0:2381"

apiServer:
  certSANs:
@CERT_SANS@

# `bind-address: 0.0.0.0` on these two components: by default they only listen on
# loopback, and Prometheus can then scrape neither the controller-manager nor the
# scheduler (`_k8s/observability/` shows two DOWN targets, with no explanation).
# Acceptable here because the lab lives on an isolated host-only network.
controllerManager:
  extraArgs:
    - name: bind-address
      value: "0.0.0.0"
scheduler:
  extraArgs:
    - name: bind-address
      value: "0.0.0.0"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
# Since 1.34 the kubelet reads the cgroup driver directly from the runtime through the CRI
# `RuntimeConfig` method, and this field is now only a fallback (removed in 1.38).
# What REALLY matters is `SystemdCgroup = true` on the containerd side — set by
# kubeadm/provision.sh. We keep the line: it documents the intent and covers the
# CONTAINERD_SOURCE=debian case, where containerd 1.7 does not implement `RuntimeConfig`.
cgroupDriver: systemd
