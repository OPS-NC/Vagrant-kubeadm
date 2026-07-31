# Modèle de configuration `kubeadm join --control-plane` — rendu dans
# _out/join-<node>.yaml par kubeadm/cluster-up.sh.
#
# Pourquoi un fichier de configuration plutôt que la ligne de commande imprimée par
# `kubeadm token create --print-join-command` : cette ligne ne sait pas transporter
# `node-ip`, et `kubeadm join` n'a pas de drapeau équivalent. Or sans `node-ip`, le
# node s'enregistre avec l'IP de la carte NAT partagée par toutes les VM (10.0.2.15).
#
# ⚠️ `--config` est INCOMPATIBLE avec `--certificate-key` en ligne de commande : la
#    clé doit être dans le YAML, sous `controlPlane.certificateKey` (et non à la racine,
#    contrairement à `InitConfiguration`).

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
    # On rejoint par la VIP : c'est le `controlPlaneEndpoint` du cluster, et il reste
    # joignable même si le control plane qui a fait le `init` est arrêté.
    apiServerEndpoint: "@VIP@:6443"
    caCertHashes:
      - "sha256:@CA_HASH@"
controlPlane:
  localAPIEndpoint:
    advertiseAddress: "@NODE_IP@"
    bindPort: 6443
  # Déchiffre le Secret `kubeadm-certs` (namespace kube-system), qui porte les CA du
  # cluster. ⚠️ Il expire au bout de 2 HEURES. Pour en régénérer un :
  #     kubeadm init phase upload-certs --upload-certs
  certificateKey: "@CERT_KEY@"
