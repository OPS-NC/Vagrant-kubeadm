# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Vagrant-KubeADM
# ---------------
# Monte un cluster Kubernetes « à la main » avec kubeadm sur VirtualBox, à partir de
# VM Debian 13 (bento/debian-13).
#
# La TOPOLOGIE (nombre de nodes, ressources, réseau, adressage) vit dans `lab.env`
# (gitignoré), source unique partagée avec kubeadm/cluster-up.sh et les scripts
# _k8s/*-up.sh. On part du modèle versionné :
#     cp lab.env.example lab.env
#
# Ce Vagrantfile ne fait QUE créer et préparer les VM (paquets, containerd, kubeadm,
# keepalived). Il ne bootstrape AUCUN cluster : c'est le rôle de kubeadm/cluster-up.sh,
# lancé depuis l'hôte après `vagrant up`.
#
# Parcours complet :
#     cp lab.env.example lab.env      # choisir la topologie
#     vagrant up                      # crée et prépare les VM
#     ./kubeadm/cluster-up.sh         # kubeadm init + join + kubeconfig
#     ./_k8s/platform-up.sh           # CNI, Gateway, metrics, TLS
#
# Détail du fonctionnement : voir README.md

##############################################################################
# Paramètres du lab — chargés depuis lab.env (source unique).
# Une VRAIE variable d'environnement reste prioritaire (ex. `WORKERS=6 vagrant up`).
##############################################################################

lab_env = File.join(__dir__, "lab.env")
if File.exist?(lab_env)
  File.foreach(lab_env) do |line|
    next if line =~ /\A\s*(#|$)/           # ignore commentaires et lignes vides
    key, val = line.strip.split("=", 2)
    next unless key && val
    val = val.sub(/\s+#.*\z/, "").strip    # retire un commentaire de fin de ligne
    ENV[key] ||= val                       # ||= : une vraie variable d'env gagne
  end
end

# --- Versions ---------------------------------------------------------------
# Ces défauts DOIVENT rester alignés sur lab.env.example : sans lab.env, le
# Vagrantfile et cluster-up.sh retombent chacun sur les leurs, et deux valeurs
# divergentes donnent un cluster incohérent (paquets 1.36, config générée pour 1.35).
K8S_VERSION       = ENV["K8S_VERSION"]       || "1.36.3"
K8S_APT_MINOR     = ENV["K8S_APT_MINOR"]     || "v1.36"
CONTAINERD_SOURCE = ENV["CONTAINERD_SOURCE"] || "docker"
REGISTRY_MIRROR   = ENV["REGISTRY_MIRROR"]   || ""

# --- Topologie --------------------------------------------------------------
CONTROL_PLANES = (ENV["CONTROL_PLANES"] || 1).to_i   # 1 = simple ; 3 = HA (quorum etcd)
WORKERS        = (ENV["WORKERS"]        || 2).to_i

CP_MEM = (ENV["CP_MEM"] || 3072).to_i ; CP_CPU = (ENV["CP_CPU"] || 2).to_i
WK_MEM = (ENV["WK_MEM"] || 2048).to_i ; WK_CPU = (ENV["WK_CPU"] || 2).to_i

BOX         = ENV["BOX"]         || "bento/debian-13"
NODE_PREFIX = ENV["NODE_PREFIX"] || "k8s"

# --- Réseau -----------------------------------------------------------------
NETWORK = ENV["NETWORK"] || "192.168.56"
VIP     = ENV["VIP"]     || "#{NETWORK}.5"

CP_IP_START = (ENV["CP_IP_START"] || 10).to_i  ; CP_IP_STEP = (ENV["CP_IP_STEP"] || 10).to_i
WK_IP_START = (ENV["WK_IP_START"] || 101).to_i ; WK_IP_STEP = (ENV["WK_IP_STEP"] || 1).to_i

VRRP_ROUTER_ID = (ENV["VRRP_ROUTER_ID"] || 51).to_i

##############################################################################
# Construction de la liste des nodes
#   control plane i -> k8s-cp1=.10, k8s-cp2=.20, k8s-cp3=.30   (CP_IP_START/STEP)
#   worker       i  -> k8s-w1=.101, k8s-w2=.102, …             (WK_IP_START/STEP)
# Le nom de la VM EST le hostname du node Kubernetes.
##############################################################################

if CONTROL_PLANES < 1
  raise "Vagrant-KubeADM : CONTROL_PLANES=#{CONTROL_PLANES} — il en faut au moins 1."
end
if WORKERS < 0
  raise "Vagrant-KubeADM : WORKERS=#{WORKERS} — valeur négative."
end
# etcd tient le quorum à (n/2)+1 : 2 membres n'en tolèrent AUCUN en panne, tout en
# coûtant deux fois plus cher qu'un seul. Un nombre pair est donc toujours un piège.
if CONTROL_PLANES.even?
  raise "Vagrant-KubeADM : CONTROL_PLANES=#{CONTROL_PLANES} est PAIR — etcd exige un " \
        "nombre impair pour tenir un quorum utile (1, 3, 5). Avec 2 membres, la perte " \
        "d'un seul node fige l'API."
end

servers = []
(1..CONTROL_PLANES).each do |i|
  servers << { name: "#{NODE_PREFIX}-cp#{i}", role: "controlplane", index: i,
               ip: "#{NETWORK}.#{CP_IP_START + (i - 1) * CP_IP_STEP}",
               mem: CP_MEM, cpu: CP_CPU }
end
(1..WORKERS).each do |i|
  servers << { name: "#{NODE_PREFIX}-w#{i}", role: "worker", index: i,
               ip: "#{NETWORK}.#{WK_IP_START + (i - 1) * WK_IP_STEP}",
               mem: WK_MEM, cpu: WK_CPU }
end

# Garde-fou : .1 = passerelle host-only, .2 = serveur DHCP VirtualBox,
# .100 = serveur DHCP host-only PAR DÉFAUT de VirtualBox, et la VIP de l'API.
# Un node qui atterrit sur l'une d'elles produit un lab cassé de façon très obscure.
reserved = { "#{NETWORK}.1" => "passerelle host-only",
             "#{NETWORK}.2" => "serveur DHCP VirtualBox",
             "#{NETWORK}.100" => "DHCP host-only par défaut de VirtualBox",
             VIP => "VIP de l'API Kubernetes" }
servers.each do |s|
  if reserved.key?(s[:ip])
    raise "Vagrant-KubeADM : l'IP #{s[:ip]} (#{s[:name]}) est réservée — #{reserved[s[:ip]]}. " \
          "Ajuste CONTROL_PLANES/WORKERS ou le plan d'adressage (CP_IP_*/WK_IP_*) dans lab.env."
  end
end

# Garde-fou : deux nodes sur la même IP (arrive vite en bricolant CP_IP_STEP/WK_IP_START).
doublons = servers.map { |s| s[:ip] }.tally.select { |_, n| n > 1 }.keys
unless doublons.empty?
  raise "Vagrant-KubeADM : IP en double #{doublons.join(', ')} — les plages control plane " \
        "et worker se chevauchent. Vérifie CP_IP_START/CP_IP_STEP et WK_IP_START/WK_IP_STEP."
end

# Table /etc/hosts poussée à l'identique sur tous les nodes : la résolution des noms
# ne doit dépendre ni du DNS du lab, ni de l'ordre de démarrage des VM.
HOSTS_ENTRIES = servers.map { |s| "#{s[:ip]}  #{s[:name]}" }.join("\n")
# Liste des IP de control plane : keepalived s'en sert pour ses pairs VRRP en UNICAST
# (plus déterministe que le multicast sur un switch virtuel VirtualBox).
CP_IPS = servers.select { |s| s[:role] == "controlplane" }.map { |s| s[:ip] }.join(",")

##############################################################################
# Vagrant
##############################################################################

Vagrant.configure("2") do |config|
  config.vm.box              = BOX
  config.vm.box_check_update = false

  # Le dossier synchronisé est un ROUAGE du lab, pas un confort : cluster-up.sh rend
  # les configs kubeadm dans `_out/` sur l'hôte, et chaque node les lit dans /vagrant.
  # C'est ce qui évite tout scp et toute copie de secrets par la ligne de commande.
  config.vm.synced_folder ".", "/vagrant"

  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
  end

  servers.each do |s|
    config.vm.define s[:name] do |node|
      node.vm.hostname = s[:name]

      # NIC1 = NAT VirtualBox (Internet), NIC2 = host-only (réseau du cluster).
      node.vm.network "private_network", ip: s[:ip]

      node.vm.provider "virtualbox" do |vb|
        vb.name   = s[:name]
        vb.memory = s[:mem]
        vb.cpus   = s[:cpu]
        vb.gui    = false
        vb.linked_clone = true   # clones liés : ~1 seule copie de la box sur le disque

        # Sans cela, l'horloge d'une VM suspendue puis reprise dérive, et etcd —
        # très sensible à la dérive d'horloge — perd son leader sans raison visible.
        vb.customize ["guestproperty", "set", :id,
                      "/VirtualBox/GuestAdd/VBoxService/--timesync-set-threshold", 1000]
      end

      # Préparation système : paquets, containerd, kubeadm, keepalived (CP uniquement).
      # AUCUN `kubeadm init` ici — cf. kubeadm/cluster-up.sh.
      node.vm.provision "shell",
        path: "kubeadm/provision.sh",
        env: {
          "DEBIAN_FRONTEND"   => "noninteractive",
          "NODE_NAME"         => s[:name],
          "NODE_ROLE"         => s[:role],
          "NODE_INDEX"        => s[:index].to_s,
          "NODE_IP"           => s[:ip],
          "NETWORK"           => NETWORK,
          "VIP"               => VIP,
          "CP_IPS"            => CP_IPS,
          "VRRP_ROUTER_ID"    => VRRP_ROUTER_ID.to_s,
          "K8S_VERSION"       => K8S_VERSION,
          "K8S_APT_MINOR"     => K8S_APT_MINOR,
          "CONTAINERD_SOURCE" => CONTAINERD_SOURCE,
          "REGISTRY_MIRROR"   => REGISTRY_MIRROR,
          "HOSTS_ENTRIES"     => HOSTS_ENTRIES,
        }
    end
  end
end
