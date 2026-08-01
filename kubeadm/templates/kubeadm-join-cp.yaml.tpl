# `kubeadm join --control-plane` configuration template — rendered into
# _out/join-<node>.yaml by kubeadm/cluster-up.sh.
#
# Why a configuration file rather than the command line printed by
# `kubeadm token create --print-join-command`: that line cannot carry `node-ip`, and
# `kubeadm join` has no equivalent flag. And without `node-ip`, the node registers with
# the IP of the NAT NIC shared by every VM (10.0.2.15).
#
# ⚠️ `--config` is INCOMPATIBLE with `--certificate-key` on the command line: the key
#    has to be in the YAML, under `controlPlane.certificateKey` (and not at the root,
#    unlike `InitConfiguration`).

apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
nodeRegistration:
  name: "@NODE_NAME@"
  criSocket: unix:///run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  kubeletExtraArgs:
    - name: node-ip
      value: "@NODE_IP@"
discovery:
  bootstrapToken:
    token: "@TOKEN@"
    # We join through the VIP: it is the cluster's `controlPlaneEndpoint`, and it stays
    # reachable even if the control plane that did the `init` is stopped.
    apiServerEndpoint: "@VIP@:6443"
    caCertHashes:
      - "sha256:@CA_HASH@"
controlPlane:
  localAPIEndpoint:
    advertiseAddress: "@NODE_IP@"
    bindPort: 6443
  # Decrypts the `kubeadm-certs` Secret (kube-system namespace), which carries the
  # cluster CAs. ⚠️ It expires after 2 HOURS. To regenerate one:
  #     kubeadm init phase upload-certs --upload-certs
  certificateKey: "@CERT_KEY@"
