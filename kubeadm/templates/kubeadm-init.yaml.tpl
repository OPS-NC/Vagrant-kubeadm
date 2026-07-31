# Modèle de configuration `kubeadm init` — rendu dans _out/kubeadm-init.yaml par
# kubeadm/cluster-up.sh (substitution des marqueurs @NOM@).
#
# API `kubeadm.k8s.io/v1beta4` : c'est la version courante et celle par défaut depuis
# Kubernetes 1.31. `v1beta3` est dépréciée.
#
# ⚠️ LE PIÈGE DE LA MIGRATION v1beta3 -> v1beta4 : `extraArgs` et `kubeletExtraArgs`
#    ne sont PLUS des dictionnaires mais des LISTES de {name, value} — le changement a
#    été fait pour autoriser un même drapeau plusieurs fois. Tout fichier écrit avant
#    1.31 est donc invalide tel quel, et l'erreur renvoyée n'est pas explicite.
#      v1beta3 :  extraArgs: {bind-address: "0.0.0.0"}
#      v1beta4 :  extraArgs: [{name: bind-address, value: "0.0.0.0"}]

apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  # L'IP RÉELLE de ce node, surtout pas la VIP : c'est l'adresse sur laquelle CET
  # apiserver écoute. La VIP, elle, est le `controlPlaneEndpoint` partagé (plus bas).
  advertiseAddress: "@NODE_IP@"
  bindPort: 6443
nodeRegistration:
  name: "@NODE_NAME@"
  criSocket: unix:///run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  kubeletExtraArgs:
    # ⚠️ LE piège numéro un d'un lab Vagrant. Chaque VM a une carte NAT eth0 en
    #    10.0.2.15 — LA MÊME sur toutes les VM. Sans `node-ip`, le kubelet choisit
    #    cette route par défaut et TOUS les nodes s'enregistrent avec la même adresse :
    #    `kubectl get nodes -o wide` semble correct, mais les logs, `kubectl exec`,
    #    les probes et le trafic inter-node partent au mauvais endroit.
    - name: node-ip
      value: "@NODE_IP@"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v@K8S_VERSION@
clusterName: @CLUSTER_NAME@

# `controlPlaneEndpoint` est figé dans les certificats et dans tous les kubeconfig au
# moment du `init`. On y met la VIP keepalived MÊME avec un seul control plane : c'est
# ce qui permet d'ajouter un CP plus tard par un simple `join`, sans régénérer les
# certificats ni redistribuer les kubeconfig.
controlPlaneEndpoint: "@VIP@:6443"

networking:
  # ⚠️ Ce CIDR doit être celui que le CNI annonce réellement. Cilium en mode
  #    cluster-pool part par défaut sur 10.0.0.0/8, sans aucun rapport avec ce qui est
  #    déclaré ici : _k8s/cilium/cilium-up.sh lui repasse donc POD_CIDR explicitement.
  podSubnet: "@POD_CIDR@"
  serviceSubnet: "@SERVICE_CIDR@"
  dnsDomain: cluster.local

etcd:
  local:
    # etcd empilé (sur les control planes) : c'est le défaut kubeadm et le bon choix
    # pour un lab. Il est très sensible à la latence de fsync — d'où l'intérêt de
    # garder les disques des VM sur un SSD (cf. TROUBLESHOOTING.md).
    dataDir: /var/lib/etcd

apiServer:
  certSANs:
@CERT_SANS@

# `bind-address: 0.0.0.0` sur ces deux composants : par défaut ils n'écoutent qu'en
# loopback, et Prometheus ne peut alors scruter ni le controller-manager ni le
# scheduler (`_k8s/observability/` affiche deux cibles DOWN, sans explication).
# Acceptable ici parce que le lab vit sur un réseau host-only isolé.
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
# Depuis 1.34 le kubelet lit le cgroup driver directement auprès du runtime par la
# méthode CRI `RuntimeConfig`, et ce champ n'est plus qu'un repli (retiré en 1.38).
# Ce qui compte VRAIMENT, c'est `SystemdCgroup = true` côté containerd — posé par
# kubeadm/provision.sh. On garde la ligne : elle documente l'intention et couvre le
# cas CONTAINERD_SOURCE=debian, où containerd 1.7 n'implémente pas `RuntimeConfig`.
cgroupDriver: systemd
