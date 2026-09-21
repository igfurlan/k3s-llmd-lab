# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# 3-node Rocky Linux 9 cluster on VirtualBox, for a k3s + llm-d AI lab.
#
#   vagrant up                 # create + provision all three nodes
#   vagrant ssh k3s-server     # log in to one
#   vagrant status             # what's running
#   vagrant halt               # shut down, keep the VMs
#   vagrant destroy -f         # delete everything
#
# Deliberately minimal: no extra disks, no storage layer. Rook/Ceph is a
# separate project with its own (much larger) node requirements.

NODES = {
  # hostname       => [ip,              cpus, memory_mb]
  "k3s-server"     => ["192.168.56.11",    4,      6144],
  "k3s-agent-1"    => ["192.168.56.12",    4,      6144],
  "k3s-agent-2"    => ["192.168.56.13",    4,      6144],
}.freeze
# Total 18 GB of the host's ~30.8 GB, leaving ~12 GB for Windows.

BOX         = "rockylinux/9"
BOX_VERSION = "5.0.0"   # pinned so the build is reproducible.
                        # NOT 6.0.0: the registry lists it as active but the
                        # .box artifact 404s. 5.0.0 and 4.0.0 download fine.

# /etc/hosts entries for every node. Built as plain lines to keep the
# shell script free of heredoc-escaping surprises.
hosts_script = "set -eu\nsed -i '/# vagrant-k3s-lab$/d' /etc/hosts\n"
NODES.each do |name, (ip, _cpus, _mem)|
  hosts_script += "echo '#{ip} #{name} # vagrant-k3s-lab' >> /etc/hosts\n"
end

PREREQS = <<~'SHELL'
  set -euo pipefail

  # --- Kubernetes requires swap off -------------------------------------
  swapoff -a
  sed -i '/[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab

  # --- k3s docs recommend no firewalld; SELinux stays enforcing ---------
  systemctl disable --now firewalld 2>/dev/null || true

  # --- clock sync: cert validity and Prometheus timestamps depend on it -
  dnf install -y -q chrony curl tar iproute
  systemctl enable --now chronyd

  dnf update -y -q

  # --- report what this guest can actually do ---------------------------
  echo "=============================================================="
  echo " NODE:   $(hostname)   $(cat /etc/rocky-release)"
  echo " KERNEL: $(uname -r)"
  echo " RAM:    $(free -h | awk '/^Mem:/{print $2}')   CPUS: $(nproc)"
  echo " SWAP:   $(free -h | awk '/^Swap:/{print $2}')  (must be 0B)"
  echo "--------------------------------------------------------------"

  # k3s must be pinned to the host-only NIC, not the NAT one (10.0.2.15
  # is identical on every VM). These are the names we need for --node-ip
  # and --flannel-iface.
  echo " INTERFACES:"
  ip -br a | sed 's/^/   /'
  echo "--------------------------------------------------------------"

  # CPU flags gate the AI-lab plan: the real vLLM CPU backend needs AVX-512.
  AVX=$(grep -o 'avx[^ ]*' /proc/cpuinfo | sort -u | tr '\n' ' ')
  echo " AVX FLAGS: ${AVX:-NONE}"
  case "$AVX" in
    *avx512*) echo "   -> AVX-512 present: real vLLM CPU backend is possible." ;;
    *avx2*)   echo "   -> AVX2 only: use llm-d-inference-sim; ollama will work." ;;
    *avx*)    echo "   -> AVX only: ollama will be slow. Simulator required." ;;
    *)        echo "   -> NO AVX AT ALL: expect poor ollama performance." ;;
  esac
  echo "=============================================================="
SHELL

Vagrant.configure("2") do |config|
  config.vm.box          = BOX
  config.vm.box_version  = BOX_VERSION
  config.vm.boot_timeout = 600

  # The box ships without Guest Additions, so shared folders would fail.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.provider "virtualbox" do |vb|
    vb.linked_clone          = true   # 3 VMs share one base image
    vb.gui                   = false
    vb.check_guest_additions = false
  end

  NODES.each_with_index do |(name, (ip, cpus, memory)), index|
    config.vm.define name, primary: (index.zero?) do |node|
      node.vm.hostname = name
      node.vm.network "private_network", ip: ip

      node.vm.provider "virtualbox" do |vb|
        vb.name   = name
        vb.cpus   = cpus
        vb.memory = memory
      end

      node.vm.provision "hosts",   type: "shell", inline: hosts_script
      node.vm.provision "prereqs", type: "shell", inline: PREREQS
    end
  end
end
