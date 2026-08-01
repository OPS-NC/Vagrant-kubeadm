# `kubeadm join` (worker) configuration template — rendered into _out/join-<node>.yaml
# by kubeadm/cluster-up.sh.
#
# Identical to the control-plane template, without the `controlPlane` block: a worker
# hosts neither apiserver nor etcd, and therefore needs no certificate key.

apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
nodeRegistration:
  name: "@NODE_NAME@"
  criSocket: unix:///run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  kubeletExtraArgs:
    # Without this, the worker registers with the IP of its NAT NIC (10.0.2.15),
    # identical on every VM. See the detailed comment in kubeadm-init.yaml.tpl.
    - name: node-ip
      value: "@NODE_IP@"
discovery:
  bootstrapToken:
    token: "@TOKEN@"
    apiServerEndpoint: "@VIP@:6443"
    caCertHashes:
      - "sha256:@CA_HASH@"
