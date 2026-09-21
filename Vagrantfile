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

# How the nodes reach each other. VirtualBox 7.2.x has open, unfixed networking
# regressions on Windows hosts (GitHub VirtualBox/virtualbox#136, #345) where
# guests hang while bringing a NIC up. This switch exists to isolate that.
#
#   :hostonly - normal. Host reaches the nodes directly at 192.168.56.x.
#               Goes through the Windows NDIS filter driver (VBoxNetLwf).
#   :intnet   - VirtualBox's internal switch. Node-to-node still works and the
#               Windows host network stack is bypassed entirely. The host can no
#               longer reach the nodes on that subnet, so kubectl needs a
#               forwarded port.
#   :none     - diagnostic only. NAT only, no second NIC, no cluster network.
CLUSTER_NET = :hostonly

BOX         = "rockylinux/9"
BOX_VERSION = "5.0.0"   # pinned so the build is reproducible.
                        # NOT 6.0.0: the registry lists it as active but the
                        # .box artifact 404s. 5.0.0 and 4.0.0 download fine.

K3S_VERSION = "v1.36.4+k3s1"   # stable channel as of 2026-09-21

# The first node in NODES is the control plane; the rest join it as agents.
SERVER_NAME = NODES.keys.first
SERVER_IP   = NODES[SERVER_NAME][0]

# Cluster join secret.
#
# Generated once on first use and kept in .k3s-token, which .gitignore excludes.
# Anyone holding this can join a node to the cluster, so it must never be
# committed — hardcoding it here would publish a credential to a public repo.
# Delete the file to roll the token; the cluster then needs rebuilding.
require "securerandom"
TOKEN_FILE = File.join(__dir__, ".k3s-token")
K3S_TOKEN  =
  if File.exist?(TOKEN_FILE) && !File.read(TOKEN_FILE).strip.empty?
    File.read(TOKEN_FILE).strip
  else
    SecureRandom.hex(32).tap do |t|
      File.write(TOKEN_FILE, t + "\n")
      File.chmod(0o600, TOKEN_FILE) rescue nil
    end
  end

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

  # Userspace gets patched; the kernel does NOT.
  #
  # Installing a newer kernel and rebooting hangs the guest roughly 7.5s in,
  # right after device init and before the root pivot — no systemd, no sshd,
  # so Vagrant sits at "Waiting for machine to boot" until it times out. It
  # happens with or without the second NIC, so it is not a networking fault.
  # VirtualBox runs under Hyper-V's platform here (NEM in VBox.log) rather than
  # native AMD-V, and the box's own kernel is the one known to boot in that
  # environment. Pin it.
  dnf update -y -q --exclude=kernel*

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

# --- k3s control plane -------------------------------------------------------
#
# --node-ip and --flannel-iface are mandatory here, not tuning. Every Vagrant VM
# carries a NAT adapter at 10.0.2.15 — the same address on all three machines —
# and k3s picks its node IP from the default route, which points there. Without
# these flags all three nodes register as 10.0.2.15, the cluster forms, and pod
# networking then fails in ways that look like anything but a networking problem.
#
# traefik is disabled because llm-d brings its own Envoy-based gateway; two
# ingress controllers competing for 80/443 through ServiceLB is a bad time.
# ServiceLB itself stays enabled so that gateway can still get an external IP.
K3S_SERVER = <<~SHELL
  set -euo pipefail

  if systemctl is-active --quiet k3s; then
    echo "k3s server already running — skipping install."
  else
    echo "Installing k3s #{K3S_VERSION} (server) ..."
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="#{K3S_VERSION}" \
      K3S_TOKEN="#{K3S_TOKEN}" \
      INSTALL_K3S_EXEC="server \
        --node-ip=#{SERVER_IP} \
        --flannel-iface=eth1 \
        --tls-san=#{SERVER_IP} \
        --disable=traefik \
        --write-kubeconfig-mode=0644" \
      sh -
  fi

  # k3s installs to /usr/local/bin, which is NOT on the PATH inside Vagrant's
  # provisioner shell. Call it by absolute path.
  K3S=/usr/local/bin/k3s

  # Agents are provisioned next and will try to join immediately, so do not
  # return until the API actually answers.
  echo -n "Waiting for the API server "
  for i in $(seq 1 90); do
    if $K3S kubectl get --raw=/readyz >/dev/null 2>&1; then echo " ready"; break; fi
    echo -n "."
    sleep 5
  done

  $K3S kubectl get nodes -o wide
SHELL

# --- k3s agents --------------------------------------------------------------
k3s_agent = lambda do |ip|
  <<~SHELL
    set -euo pipefail

    if systemctl is-active --quiet k3s-agent; then
      echo "k3s agent already running — skipping install."
      exit 0
    fi

    echo -n "Waiting for #{SERVER_IP}:6443 "
    for i in $(seq 1 90); do
      # Any HTTP response means the port is serving; 401 is a fine answer here.
      if curl -sk --max-time 3 -o /dev/null https://#{SERVER_IP}:6443/ 2>/dev/null; then
        echo " up"; break
      fi
      echo -n "."
      sleep 5
    done

    echo "Installing k3s #{K3S_VERSION} (agent) ..."
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="#{K3S_VERSION}" \
      K3S_URL="https://#{SERVER_IP}:6443" \
      K3S_TOKEN="#{K3S_TOKEN}" \
      INSTALL_K3S_EXEC="agent \
        --node-ip=#{ip} \
        --flannel-iface=eth1" \
      sh -

    systemctl is-active k3s-agent && echo "joined #{SERVER_IP} as #{ip}"
  SHELL
end

Vagrant.configure("2") do |config|
  config.vm.box          = BOX
  config.vm.box_version  = BOX_VERSION
  # Generous, deliberately. VirtualBox has no AMD-V here and falls back to
  # NEM (Windows Hypervisor Platform), where every VM exit is expensive and
  # boots can run many minutes. At the default timeout Vagrant gives up on a
  # guest that is still booting, which is indistinguishable from a hang.
  config.vm.boot_timeout = 1800

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

      case CLUSTER_NET
      when :hostonly
        node.vm.network "private_network", ip: ip
      when :intnet
        node.vm.network "private_network", ip: ip, virtualbox__intnet: "k3slab"
      when :none
        # No cluster NIC. Boots on NAT alone, for isolating network faults.
      else
        raise "CLUSTER_NET must be :hostonly, :intnet or :none"
      end

      node.vm.provider "virtualbox" do |vb|
        vb.name   = name
        vb.cpus   = cpus
        vb.memory = memory

        # Give the guest the KVM paravirtualised clock. VirtualBox picks
        # "legacy" for a generic Linux_64 guest, which leaves it reading raw
        # TSC; under Hyper-V compatibility mode that drifts, the kernel's
        # clocksource watchdog declares TSC unstable, and the boot can hang
        # before sshd finishes coming up.
        vb.customize ["modifyvm", :id, "--paravirtprovider", "kvm"]

        # REQUIRED for vb.cpus > 1. VirtualBox needs the I/O APIC to run an SMP
        # guest; with it off it silently hands the guest a single CPU and
        # ignores the cpus setting entirely — no warning anywhere. The box
        # ships with ioapic off and Vagrant does not turn it on, so a node
        # configured for 4 vCPUs boots with 1, and everything crawls.
        #   Verify in the guest: nproc  (must match the NODES table)
        vb.customize ["modifyvm", :id, "--ioapic", "on"]
      end

      node.vm.provision "hosts",   type: "shell", inline: hosts_script
      node.vm.provision "prereqs", type: "shell", inline: PREREQS

      if name == SERVER_NAME
        node.vm.provision "k3s", type: "shell", inline: K3S_SERVER
      else
        node.vm.provision "k3s", type: "shell", inline: k3s_agent.call(ip)
      end
    end
  end
end
