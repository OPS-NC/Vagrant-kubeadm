# Modèle de configuration `kubeadm join` (worker) — rendu dans _out/join-<node>.yaml
# par kubeadm/cluster-up.sh.
#
# Identique au modèle control plane, sans le bloc `controlPlane` : un worker n'héberge
# ni apiserver, ni etcd, et n'a donc besoin d'aucune clé de certificat.

apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
nodeRegistration:
  name: "@NODE_NAME@"
  criSocket: unix:///run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  kubeletExtraArgs:
    # Sans ceci, le worker s'enregistre avec l'IP de sa carte NAT (10.0.2.15),
    # identique sur toutes les VM. Cf. le commentaire détaillé dans kubeadm-init.yaml.tpl.
    - name: node-ip
      value: "@NODE_IP@"
discovery:
  bootstrapToken:
    token: "@TOKEN@"
    apiServerEndpoint: "@VIP@:6443"
    caCertHashes:
      - "sha256:@CA_HASH@"
