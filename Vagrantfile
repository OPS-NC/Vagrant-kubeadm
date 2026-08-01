# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Vagrant-KubeADM
# ---------------
# Builds a Kubernetes cluster "by hand" with kubeadm on VirtualBox, from Debian 13 VMs
# (bento/debian-13).
#
# The TOPOLOGY (node count, resources, network, addressing) lives in `lab.env`
# (gitignored), the single source shared with kubeadm/cluster-up.sh and the _k8s/*-up.sh
# scripts. Start from the versioned template:
#     cp lab.env.example lab.env
#
# This Vagrantfile ONLY creates and prepares the VMs (packages, containerd, kubeadm,
# keepalived). It bootstraps NO cluster: that is kubeadm/cluster-up.sh's job, run from the
# host after `vagrant up`.
#
# The full path:
#     cp lab.env.example lab.env      # pick the topology
#     vagrant up                      # creates and prepares the VMs
#     ./kubeadm/cluster-up.sh         # kubeadm init + join + kubeconfig
#     ./_k8s/platform-up.sh           # CNI, Gateway, metrics, TLS
#
# How it all works in detail: see README.md

##############################################################################
# Lab parameters — loaded from lab.env (the single source).
# A REAL environment variable still wins (e.g. `WORKERS=6 vagrant up`).
##############################################################################

lab_env = File.join(__dir__, "lab.env")
if File.exist?(lab_env)
  File.foreach(lab_env) do |line|
    next if line =~ /\A\s*(#|$)/           # skip comments and blank lines
    key, val = line.strip.split("=", 2)
    next unless key && val
    val = val.sub(/\s+#.*\z/, "").strip    # strip a trailing comment
    ENV[key] ||= val                       # ||= : a real env var wins
  end
end

# --- Versions ---------------------------------------------------------------
# These defaults MUST stay aligned with lab.env.example: without a lab.env, the
# Vagrantfile and cluster-up.sh each fall back to their own, and two diverging values
# give an incoherent cluster (1.36 packages, configuration generated for 1.35).
K8S_VERSION       = ENV["K8S_VERSION"]       || "1.36.3"
K8S_APT_MINOR     = ENV["K8S_APT_MINOR"]     || "v1.36"
CONTAINERD_SOURCE = ENV["CONTAINERD_SOURCE"] || "docker"
REGISTRY_MIRROR   = ENV["REGISTRY_MIRROR"]   || ""
SYSTEM_UPGRADE    = ENV["SYSTEM_UPGRADE"]    || "true"
# Passed on to provision.sh so a worker does not pre-pull a kube-proxy image that will
# never be used (see step 7 of provision.sh).
KUBE_PROXY_REPLACEMENT = ENV["KUBE_PROXY_REPLACEMENT"] || "true"

# --- Topology ---------------------------------------------------------------
CONTROL_PLANES = (ENV["CONTROL_PLANES"] || 1).to_i   # 1 = single ; 3 = HA (etcd quorum)
WORKERS        = (ENV["WORKERS"]        || 2).to_i

CP_MEM = (ENV["CP_MEM"] || 3072).to_i ; CP_CPU = (ENV["CP_CPU"] || 2).to_i
WK_MEM = (ENV["WK_MEM"] || 2048).to_i ; WK_CPU = (ENV["WK_CPU"] || 2).to_i

BOX         = ENV["BOX"]         || "bento/debian-13"
NODE_PREFIX = ENV["NODE_PREFIX"] || "k8s"

# --- Network ----------------------------------------------------------------
NETWORK = ENV["NETWORK"] || "192.168.56"
VIP     = ENV["VIP"]     || "#{NETWORK}.5"

CP_IP_START = (ENV["CP_IP_START"] || 10).to_i  ; CP_IP_STEP = (ENV["CP_IP_STEP"] || 10).to_i
WK_IP_START = (ENV["WK_IP_START"] || 101).to_i ; WK_IP_STEP = (ENV["WK_IP_STEP"] || 1).to_i

VRRP_ROUTER_ID = (ENV["VRRP_ROUTER_ID"] || 51).to_i

##############################################################################
# Building the node list
#   control plane i -> k8s-cp1=.10, k8s-cp2=.20, k8s-cp3=.30   (CP_IP_START/STEP)
#   worker       i  -> k8s-w1=.101, k8s-w2=.102, …             (WK_IP_START/STEP)
# The VM name IS the Kubernetes node's hostname.
##############################################################################

if CONTROL_PLANES < 1
  raise "Vagrant-KubeADM: CONTROL_PLANES=#{CONTROL_PLANES} — at least 1 is required."
end
if WORKERS < 0
  raise "Vagrant-KubeADM: WORKERS=#{WORKERS} — negative value."
end
# etcd holds quorum at (n/2)+1: 2 members tolerate NO failure at all, while costing twice
# as much as a single one. So an even number is always a trap.
if CONTROL_PLANES.even?
  raise "Vagrant-KubeADM: CONTROL_PLANES=#{CONTROL_PLANES} is EVEN — etcd requires an " \
        "odd number to hold a useful quorum (1, 3, 5). With 2 members, losing a single " \
        "node freezes the API."
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

# Guard rail: .1 = host-only gateway, .2 = VirtualBox DHCP server,
# .100 = VirtualBox's DEFAULT host-only DHCP server, and the API VIP.
# A node landing on one of those produces a lab broken in a very obscure way.
reserved = { "#{NETWORK}.1" => "host-only gateway",
             "#{NETWORK}.2" => "VirtualBox DHCP server",
             "#{NETWORK}.100" => "VirtualBox's default host-only DHCP",
             VIP => "Kubernetes API VIP" }
servers.each do |s|
  if reserved.key?(s[:ip])
    raise "Vagrant-KubeADM: the IP #{s[:ip]} (#{s[:name]}) is reserved — #{reserved[s[:ip]]}. " \
          "Adjust CONTROL_PLANES/WORKERS or the addressing scheme (CP_IP_*/WK_IP_*) in lab.env."
  end
end

# Guard rail: the range reserved for LoadBalancer Services (Cilium's L2 announcement). A
# node landing in it enters an ARP conflict with the Envoy Gateway — the most obscure
# failure of all, since both the node AND the UI work "every other time".
lb_start = (ENV["LB_POOL_START"] || "#{NETWORK}.200").split(".").last.to_i
lb_end   = (ENV["LB_POOL_END"]   || "#{NETWORK}.230").split(".").last.to_i
servers.each do |s|
  octet = s[:ip].split(".").last.to_i
  if octet >= lb_start && octet <= lb_end
    raise "Vagrant-KubeADM: the IP #{s[:ip]} (#{s[:name]}) falls inside the range reserved " \
          "for LoadBalancer Services (#{NETWORK}.#{lb_start}-#{NETWORK}.#{lb_end}). Reduce " \
          "WORKERS, or move LB_POOL_START/LB_POOL_END in lab.env."
  end
end

# Guard rail: valid last octet. `WORKERS=160` would produce `192.168.56.260`, which
# VirtualBox rejects with a message that mentions neither Vagrant nor the lab.
servers.each do |s|
  octet = s[:ip].split(".").last.to_i
  if octet < 3 || octet > 254
    raise "Vagrant-KubeADM: the IP #{s[:ip]} (#{s[:name]}) is outside the " \
          "#{NETWORK}.0/24 network. Reduce CONTROL_PLANES/WORKERS or revisit CP_IP_*/WK_IP_*."
  end
end

# Guard rail: two nodes on the same IP (easily done while tweaking CP_IP_STEP/WK_IP_START).
duplicates = servers.map { |s| s[:ip] }.tally.select { |_, n| n > 1 }.keys
unless duplicates.empty?
  raise "Vagrant-KubeADM: duplicate IP #{duplicates.join(', ')} — the control-plane and " \
        "worker ranges overlap. Check CP_IP_START/CP_IP_STEP and WK_IP_START/WK_IP_STEP."
end

# An /etc/hosts table pushed identically to every node: name resolution must depend
# neither on the lab's DNS nor on the VMs' boot order.
HOSTS_ENTRIES = servers.map { |s| "#{s[:ip]}  #{s[:name]}" }.join("\n")
# The list of control-plane IPs: keepalived uses it for its VRRP peers in UNICAST (more
# deterministic than multicast on a VirtualBox virtual switch).
CP_IPS = servers.select { |s| s[:role] == "controlplane" }.map { |s| s[:ip] }.join(",")

##############################################################################
# Vagrant
##############################################################################

Vagrant.configure("2") do |config|
  config.vm.box              = BOX
  config.vm.box_check_update = false

  # The synced folder is a MECHANISM of the lab, not a convenience: cluster-up.sh renders
  # the kubeadm configs into `_out/` on the host, and every node reads them in /vagrant.
  # That is what avoids any scp and any secret passed on a command line.
  config.vm.synced_folder ".", "/vagrant"

  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
  end

  servers.each do |s|
    config.vm.define s[:name] do |node|
      node.vm.hostname = s[:name]

      # NIC1 = VirtualBox NAT (Internet), NIC2 = host-only (the cluster network).
      node.vm.network "private_network", ip: s[:ip]

      node.vm.provider "virtualbox" do |vb|
        vb.name   = s[:name]
        vb.memory = s[:mem]
        vb.cpus   = s[:cpu]
        vb.gui    = false
        vb.linked_clone = true   # linked clones: ~a single copy of the box on disk

        # Without this, the clock of a VM suspended then resumed drifts, and etcd — very
        # sensitive to clock drift — loses its leader for no visible reason.
        vb.customize ["guestproperty", "set", :id,
                      "/VirtualBox/GuestAdd/VBoxService/--timesync-set-threshold", 1000]
      end

      # System preparation: packages, containerd, kubeadm, keepalived (CP only).
      # NO `kubeadm init` here — see kubeadm/cluster-up.sh.
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
          "CP_IP_START"       => CP_IP_START.to_s,
          "CP_IP_STEP"        => CP_IP_STEP.to_s,
          "VRRP_ROUTER_ID"    => VRRP_ROUTER_ID.to_s,
          "K8S_VERSION"       => K8S_VERSION,
          "K8S_APT_MINOR"     => K8S_APT_MINOR,
          "CONTAINERD_SOURCE" => CONTAINERD_SOURCE,
          "REGISTRY_MIRROR"   => REGISTRY_MIRROR,
          "SYSTEM_UPGRADE"    => SYSTEM_UPGRADE,
          "KUBE_PROXY_REPLACEMENT" => KUBE_PROXY_REPLACEMENT,
          "HOSTS_ENTRIES"     => HOSTS_ENTRIES,
        }
    end
  end
end
