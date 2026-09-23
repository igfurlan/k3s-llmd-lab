# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# 3-node Rocky Linux 9 cluster on Hyper-V, for a k3s + llm-d AI lab.
#
# EVERY vagrant command here must run from an ELEVATED PowerShell. Hyper-V's
# management API refuses non-administrators outright:
#   "You do not have the required permission to complete this task."
# Vagrant surfaces that as an unrelated-looking failure.
#
#   # once per host, elevated:
#   powershell -ExecutionPolicy Bypass -File scripts\hyperv-create-switch.ps1
#
#   # then, from this directory:
#   vagrant up --no-provision   # create + boot; each node gains its cluster NIC
#   vagrant provision           # cluster IPs, then k3s (server first, agents after)
#
#   vagrant ssh k3s-server      # log in to one
#   vagrant halt                # shut down, keep the VMs
#   vagrant destroy -f          # delete everything
#
# WHY TWO COMMANDS INSTEAD OF ONE `vagrant up`
#   Vagrant's Hyper-V provider attaches exactly one network adapter and has no
#   setting for a second (plugins/providers/hyperv/action/configure.rb passes a
#   single SwitchID). We need two: the Default Switch for DHCP and internet, and
#   a stable private network for k3s node identity. The second one is added by a
#   host-side trigger — and because these boxes are generation 1, Hyper-V cannot
#   hot-add an adapter, so the trigger shuts the VM down, adds it, and starts it
#   again. Provisioning has to happen after that, not before.
#   `vagrant up` on an existing VM is a single command again.
#
# WHY HYPER-V AT ALL
#   VirtualBox has no AMD-V on this host and runs guests on NEM, where vCPUs are
#   descheduled for seconds. See hyperv-migration-plan.md for the measurement,
#   and archive/Vagrantfile.virtualbox for the configuration it replaces.

# VirtualBox is still installed on this host and Vagrant would otherwise pick it
# first, silently building the wrong kind of VM. Setting the default here means
# plain `vagrant up` does the right thing; an explicit --provider still wins,
# and so does a VAGRANT_DEFAULT_PROVIDER already set in the environment.
ENV["VAGRANT_DEFAULT_PROVIDER"] ||= "hyperv"

NODES = {
  # hostname       => [cluster ip,      cpus, memory_mb]
  "k3s-server"     => ["192.168.58.11",    4,      6144],
  "k3s-agent-1"    => ["192.168.58.12",    4,      6144],
  "k3s-agent-2"    => ["192.168.58.13",    4,      6144],
}.freeze
# Total 18 GB of the host's ~30.8 GB, leaving ~12 GB for Windows.

# --- networking --------------------------------------------------------------
#
# Adapter 0  Default Switch   DHCP, internet, and the address Vagrant uses for
#                             SSH. Its subnet is re-randomised by Windows on
#                             every host reboot, so nothing may depend on it.
# Adapter 1  CLUSTER_SWITCH   an Internal switch, no DHCP, static addresses set
#                             by the cluster-net provisioner below. This is the
#                             only address a node is known by.
#
# The order matters and is not arbitrary: Vagrant reads the guest's IP from
# `Get-VMNetworkAdapter | Select-Object -Index 0` (scripts/get_network_config.ps1),
# so the DHCP adapter has to be the first one. A trigger-added adapter appends
# after it, which is exactly what we want.
#
# 192.168.58.0/24, not .56: VirtualBox's host-only adapter still holds
# 192.168.56.1 on this host, and two interfaces with the same address is a
# routing problem that presents as random unreachability.
CLUSTER_SWITCH   = "k3s-lab"
CLUSTER_NIC_NAME = "cluster"   # Hyper-V adapter name; the attach script keys off it
CLUSTER_IFACE    = "eth1"      # the box boots with net.ifnames=0, so eth0/eth1
CLUSTER_PREFIX   = 24

BOX         = "generic/rocky9"
BOX_VERSION = "4.3.12"   # the Rocky 9 box that publishes a hyperv provider.
                         # rockylinux/9 does not, at any version.

K3S_VERSION = "v1.36.4+k3s1"   # stable channel as of 2026-09-21

# No second disk here. The VirtualBox box had an 8.9 GB root, which forced one;
# this box is built with disk_size 131072 and `autopart --type=lvm --nohome`
# (lavabit/robox generic-hyperv-x64.json), so root has ~128 GB to itself and
# /var/lib/rancher can just live there. The prereqs banner prints root's real
# size so this assumption is checked on every run rather than trusted.

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

ATTACH_NIC_SCRIPT = File.join(__dir__, "scripts", "hyperv-attach-cluster-nic.ps1")

# /etc/hosts entries for every node. Built as plain lines to keep the
# shell script free of heredoc-escaping surprises.
hosts_script = "set -eu\nsed -i '/# vagrant-k3s-lab$/d' /etc/hosts\n"
NODES.each do |name, (ip, _cpus, _mem)|
  hosts_script += "echo '#{ip} #{name} # vagrant-k3s-lab' >> /etc/hosts\n"
end

# --- the cluster NIC, inside the guest ---------------------------------------
#
# The adapter arrives unconfigured: an Internal Hyper-V switch has no DHCP
# server, unlike the Default Switch. NetworkManager would leave it down, so the
# address is assigned here.
#
# ipv4.never-default matters. Without it NetworkManager can install a second
# default route over a network that has no gateway, and the node loses its way
# out to the internet halfway through provisioning.
cluster_net = lambda do |ip|
  <<~SHELL
    set -euo pipefail

    IFACE=#{CLUSTER_IFACE}
    ADDR=#{ip}/#{CLUSTER_PREFIX}

    if ! ip link show "$IFACE" >/dev/null 2>&1; then
      echo "*** $IFACE is missing. The cluster NIC was never attached."
      echo "*** Run, from an elevated PowerShell in this directory:"
      echo "***   vagrant halt && vagrant up"
      echo "*** and check that the '#{CLUSTER_SWITCH}' switch exists:"
      echo "***   Get-VMSwitch -Name #{CLUSTER_SWITCH}"
      exit 1
    fi

    if nmcli -t -f NAME connection show 2>/dev/null | grep -qx cluster; then
      nmcli connection modify cluster \
        ipv4.method manual ipv4.addresses "$ADDR" ipv4.never-default yes \
        ipv6.method disabled connection.autoconnect yes
    else
      nmcli connection add type ethernet con-name cluster ifname "$IFACE" \
        ipv4.method manual ipv4.addresses "$ADDR" ipv4.never-default yes \
        ipv6.method disabled connection.autoconnect yes
    fi
    nmcli connection up cluster >/dev/null

    echo "cluster network:"
    ip -br a show "$IFACE" | sed 's/^/   /'
    echo "default route (must stay on eth0):"
    ip route show default | sed 's/^/   /'
  SHELL
end

PREREQS = <<~'SHELL'
  set -euo pipefail

  # --- Kubernetes requires swap off -------------------------------------
  # This box does have swap: its kickstart uses plain `autopart`, which always
  # creates a swap LV.
  swapoff -a
  sed -i '/[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab

  # --- k3s docs recommend no firewalld; SELinux stays enforcing ---------
  systemctl disable --now firewalld 2>/dev/null || true

  # --- clock sync: cert validity and Prometheus timestamps depend on it -
  dnf install -y -q chrony curl tar iproute
  systemctl enable --now chronyd

  # Full update, kernel included.
  #
  # The VirtualBox version of this file excluded kernels, added while chasing a
  # boot hang that a new kernel appeared to trigger. That hypothesis was wrong
  # (the cause was ioapic=off capping every guest at one vCPU), and the host it
  # was compensating for is gone, so the pin is gone with it. This box ships
  # Rocky 9.3, so the first run has a lot to fetch.
  dnf update -y -q

  # Drop the package cache. Worth a few hundred MB per node, and the only cost
  # is that the next dnf command re-fetches repo metadata.
  dnf clean all -q

  # --- report what this guest can actually do ---------------------------
  echo "=============================================================="
  echo " NODE:   $(hostname)   $(cat /etc/rocky-release)"
  echo " KERNEL: $(uname -r)"
  echo " RAM:    $(free -h | awk '/^Mem:/{print $2}')   CPUS: $(nproc)"
  echo " SWAP:   $(free -h | awk '/^Swap:/{print $2}')  (must be 0B)"
  echo " ROOT:   $(df -h --output=size,avail / | tail -1 | tr -s ' ')  (size, available)"
  echo "--------------------------------------------------------------"

  # k3s must be pinned to the cluster NIC, not the DHCP one: every Vagrant VM
  # gets its default route over the switch Vagrant manages, and on the Default
  # Switch those addresses are handed out fresh on every host reboot.
  echo " INTERFACES:"
  ip -br a | sed 's/^/   /'
  echo "--------------------------------------------------------------"

  # The measurement that justified this whole migration. On VirtualBox/NEM this
  # counted 14 on the server and 6 per agent; on Hyper-V it must stay 0. A
  # non-zero count here means the guest is being descheduled and nothing above
  # the kubelet will behave.
  HRT=$(dmesg 2>/dev/null | grep -c hrtimer || true)
  echo " HRTIMER WARNINGS: ${HRT}  (must be 0)"
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

  # Informational: a kernel update only takes effect after `vagrant reload`.
  if command -v needs-restarting >/dev/null 2>&1 && ! needs-restarting -r >/dev/null 2>&1; then
    echo "--------------------------------------------------------------"
    echo " A reboot is pending (new kernel). Run: vagrant reload"
  fi
  echo "=============================================================="
SHELL

# --- k3s control plane -------------------------------------------------------
#
# --node-ip and --flannel-iface are mandatory here, not tuning. k3s picks its
# node IP from the default route, which points at the Default Switch — an
# address that changes whenever Windows re-rolls that subnet. Without these
# flags the cluster forms and then breaks in ways that look like anything but a
# networking problem.
#
# traefik is disabled because llm-d brings its own Envoy-based gateway; two
# ingress controllers competing for 80/443 through ServiceLB is a bad time.
# ServiceLB itself stays enabled so that gateway can still get an external IP.
K3S_SERVER = <<~SHELL
  set -euo pipefail

  # Server settings live in /etc/rancher/k3s/config.yaml rather than in the
  # installer's INSTALL_K3S_EXEC.
  #
  # Why: the install step below is skipped when k3s is already running, so
  # flags baked into the installer can never change on an existing cluster —
  # editing them here would silently do nothing. k3s re-reads config.yaml on
  # every start, so this file is authoritative and a changed setting is picked
  # up by restarting the service.
  mkdir -p /etc/rancher/k3s
  NEW=$(mktemp)
  {
    echo "node-ip: #{SERVER_IP}"
    echo 'flannel-iface: #{CLUSTER_IFACE}'
    echo 'write-kubeconfig-mode: "0644"'
    echo 'tls-san:'
    echo "  - #{SERVER_IP}"
    echo 'disable:'
    # traefik: llm-d brings its own Envoy-based gateway, and two ingress
    # controllers competing for 80/443 via ServiceLB is a bad time.
    echo '  - traefik'
    # metrics-server: on the VirtualBox host it sustained ~90% of a vCPU while
    # failing its own scrapes, because the runtime was slow enough that scrapes
    # never completed. That feedback loop took all three nodes NotReady at once.
    # It is a fair bet this is fine on Hyper-V — re-enable it once the cluster
    # has been stable for a while, and `kubectl top` comes back.
    echo '  - metrics-server'
  } > "$NEW"

  CONFIG_CHANGED=no
  if ! cmp -s "$NEW" /etc/rancher/k3s/config.yaml 2>/dev/null; then
    mv "$NEW" /etc/rancher/k3s/config.yaml
    CONFIG_CHANGED=yes
    echo "k3s server config written/updated."
  else
    rm -f "$NEW"
  fi

  # mktemp creates 0600 root-only, and `k3s kubectl` reads this file as the
  # invoking user — so without this every command prints three copies of
  # "open /etc/rancher/k3s/config.yaml: permission denied" before working
  # normally. Safe to make readable: this file holds no secret. The join token
  # lives in /var/lib/rancher/k3s/server/token, which stays 0600.
  # Set outside the branch above, so an existing 0600 file is corrected too.
  chmod 0644 /etc/rancher/k3s/config.yaml

  if systemctl is-active --quiet k3s; then
    echo "k3s server already running."
    if [ "$CONFIG_CHANGED" = yes ]; then
      echo "Config changed — restarting k3s to apply it."
      systemctl restart k3s
    fi
  else
    echo "Installing k3s #{K3S_VERSION} (server) ..."
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="#{K3S_VERSION}" \
      K3S_TOKEN="#{K3S_TOKEN}" \
      INSTALL_K3S_EXEC="server" \
      sh -
  fi

  # k3s installs to /usr/local/bin, which is NOT on the PATH inside Vagrant's
  # provisioner shell. Call it by absolute path.
  K3S=/usr/local/bin/k3s

  # Agents are provisioned next and will try to join immediately, so do not
  # return until the API actually answers.
  #
  # Poll a real API call rather than /readyz: /readyz can go green seconds
  # before the API will actually serve requests, and the gap is long enough that
  # the next command fails. Under set -e that aborts the whole multi-machine run
  # and later nodes are silently skipped.
  echo -n "Waiting for the API server "
  for i in $(seq 1 120); do
    if $K3S kubectl get nodes >/dev/null 2>&1; then echo " ready"; break; fi
    echo -n "."
    sleep 5
  done

  # Informational only — never fail the provisioner over a display command.
  $K3S kubectl get nodes -o wide || echo "(API still settling; not a failure)"
SHELL

# --- k3s agents --------------------------------------------------------------
k3s_agent = lambda do |ip|
  <<~SHELL
    set -euo pipefail

    # Same reasoning as the server: config.yaml is authoritative, so settings
    # can change on an already-joined node.
    mkdir -p /etc/rancher/k3s
    NEW=$(mktemp)
    {
      echo "node-ip: #{ip}"
      echo 'flannel-iface: #{CLUSTER_IFACE}'
    } > "$NEW"

    CONFIG_CHANGED=no
    if ! cmp -s "$NEW" /etc/rancher/k3s/config.yaml 2>/dev/null; then
      mv "$NEW" /etc/rancher/k3s/config.yaml
      CONFIG_CHANGED=yes
    else
      rm -f "$NEW"
    fi

    # Same as on the server: mktemp leaves it 0600 and `k3s kubectl` warns on
    # every invocation. No secret in this file.
    chmod 0644 /etc/rancher/k3s/config.yaml

    if systemctl is-active --quiet k3s-agent; then
      echo "k3s agent already running."
      if [ "$CONFIG_CHANGED" = yes ]; then
        echo "Config changed — restarting k3s-agent to apply it."
        systemctl restart k3s-agent
      fi
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
      INSTALL_K3S_EXEC="agent" \
      sh -

    systemctl is-active k3s-agent && echo "joined #{SERVER_IP} as #{ip}"
  SHELL
end

Vagrant.configure("2") do |config|
  config.vm.box         = BOX
  config.vm.box_version = BOX_VERSION

  # The box has no Hyper-V guest tools for SMB shares, and an SMB sync would
  # stop to ask for host credentials. Nothing here needs /vagrant.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.provider "hyperv" do |h|
    h.linked_clone = true   # 3 VMs share one base VHDX, as differencing disks

    # Fixed memory, deliberately.
    #
    # This box's own Vagrantfile sets maxmemory = 2048, and any maxmemory turns
    # Dynamic Memory ON (scripts/utils/VagrantVM/VagrantVM.psm1,
    # Set-VagrantVMMemory). Inherited, it would cap a 6 GB node at 2 GB. An
    # explicit nil here beats the box's value in Vagrant's config merge and
    # gives a flat allocation — which is also what we want while measuring
    # scheduling behaviour.
    h.maxmemory = nil
  end

  NODES.each_with_index do |(name, (ip, cpus, memory)), index|
    config.vm.define name, primary: (index.zero?) do |node|
      node.vm.hostname = name

      node.vm.provider "hyperv" do |h|
        h.vmname = name
        h.cpus   = cpus
        h.memory = memory
      end

      # Pin adapter 0 to the Default Switch — but only until Vagrant has
      # configured this machine once.
      #
      # `bridge:` is how the Hyper-V provider chooses a switch by name
      # (action/configure.rb). It has to be set on the first up, or Vagrant
      # stops and asks interactively which switch to use, now that the host has
      # more than one. It must NOT stay set afterwards: Vagrant applies it with
      # Connect-VMNetworkAdapter against EVERY adapter the VM has, so a later
      # `vagrant up` would drag the cluster NIC onto the Default Switch and take
      # the cluster network down. Vagrant writes this sentinel after the first
      # configure and then never prompts again.
      sentinel = File.join(__dir__, ".vagrant", "machines", name, "hyperv", "action_configure")
      unless File.exist?(sentinel)
        node.vm.network "private_network", bridge: "Default Switch"
      end

      # Add the cluster NIC on the host side, because the provider cannot.
      # Idempotent: the script exits immediately if the adapter is already
      # there, which is the normal case on every run after the first.
      [:up, :reload].each do |cmd|
        node.trigger.after cmd do |t|
          t.name = "cluster NIC"
          t.info = "Ensuring #{name} has a NIC on the #{CLUSTER_SWITCH} switch"
          t.run  = {
            inline: "powershell -NoProfile -ExecutionPolicy Bypass " \
                    "-File \"#{ATTACH_NIC_SCRIPT}\" " \
                    "-VmName #{name} -SwitchName #{CLUSTER_SWITCH} " \
                    "-AdapterName #{CLUSTER_NIC_NAME}"
          }
        end
      end

      node.vm.provision "hosts",       type: "shell", inline: hosts_script
      node.vm.provision "cluster-net", type: "shell", inline: cluster_net.call(ip)
      node.vm.provision "prereqs",     type: "shell", inline: PREREQS

      if name == SERVER_NAME
        node.vm.provision "k3s", type: "shell", inline: K3S_SERVER
      else
        node.vm.provision "k3s", type: "shell", inline: k3s_agent.call(ip)
      end
    end
  end
end
