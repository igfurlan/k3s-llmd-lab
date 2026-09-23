# k3s-llmd-lab

A three-node [k3s](https://k3s.io) cluster on Hyper-V, built to run the
[llm-d](https://llm-d.ai) distributed inference stack — provisioned from a single
Vagrantfile, on a Windows host.

The GPU in the host machine is unreachable from the VMs, so **the inference is simulated
and the orchestration is real**. That trade is deliberate, and explained below.

> The lab began on VirtualBox and moved to Hyper-V on 2026-09-22, because VirtualBox never
> gets hardware virtualization on this host and its guests were being descheduled for
> seconds at a time. [hyperv-migration-plan.md](hyperv-migration-plan.md) has the
> measurement that decided it; [archive/Vagrantfile.virtualbox](archive/Vagrantfile.virtualbox)
> is the configuration it replaced, kept for the history.

## Why simulated inference

1. **No GPU passthrough.** Discrete Device Assignment is a Windows *Server* feature, so the
   host's RTX 5070 Ti is invisible to every guest here.
2. **vLLM's CPU backend requires AVX-512.** The host CPU (Ryzen 7 9800X3D) has it. Under
   VirtualBox the guests saw `avx avx2` and nothing beyond, which ruled real vLLM out.
   Whether Hyper-V passes AVX-512 through is **re-measured on first boot** — the provisioner
   banner prints the flags, and if AVX-512 appears the plan gets a real vLLM option back.
3. **6 GB nodes.** Even with the right instruction set, a real model's weights and KV cache
   do not fit alongside a control plane and a gateway.

The resolution is [`llm-d-inference-sim`](https://github.com/llm-d/llm-d-inference-sim) — the
llm-d project's own GPU-free vLLM mock. It is OpenAI-API compliant, models prefill and decode
latency, degrades under concurrency, and emits vLLM-compatible Prometheus metrics. The gateway,
the scheduler, the routing layer and the entire observability story exercise identically. Only
the tensor math is fake.

Real inference comes from [ollama](https://ollama.com), which is built for CPU and gets its
AVX2 fast path.

## Cluster

| Node | Role | Cluster IP | vCPU | RAM |
|---|---|---|---|---|
| `k3s-server` | control plane + workload | `192.168.58.11` | 4 | 6144 MB |
| `k3s-agent-1` | workload | `192.168.58.12` | 4 | 6144 MB |
| `k3s-agent-2` | workload | `192.168.58.13` | 4 | 6144 MB |

Guests are Rocky Linux 9, from box `generic/rocky9` pinned at `4.3.12` — the Rocky box that
publishes a `hyperv` provider. Swap off, firewalld disabled, SELinux left **enforcing** —
k3s installs `k3s-selinux` and `container-selinux` itself, which is the same posture a real
RHEL deployment would have.

Memory is **fixed, not dynamic**. This box's own Vagrantfile sets `maxmemory = 2048`, and any
`maxmemory` switches Hyper-V Dynamic Memory on; inherited, it would cap a 6 GB node at 2 GB.

No second disk: the box's VHDX is 128 GB, dynamically allocated, and its kickstart gives root
essentially all of it. (The VirtualBox box had an 8.9 GB root, which is why the archived
Vagrantfile carries a 30 GB data disk and an XFS mount at `/var/lib/rancher`.)

### k3s

Installed by the Vagrantfile, pinned to `v1.36.4+k3s1`:

```
--node-ip=192.168.58.11 --flannel-iface=eth1 --tls-san=192.168.58.11
--disable=traefik --disable=metrics-server --write-kubeconfig-mode=0644
```

These live in `/etc/rancher/k3s/config.yaml`, not in the installer's `INSTALL_K3S_EXEC`.
The reason is practical: the Vagrantfile skips the install step when k3s is already running,
so anything baked into the installer can never change again on an existing cluster. k3s
re-reads `config.yaml` on every start, so editing the Vagrantfile and re-provisioning
actually does something.

`--disable=traefik` because llm-d brings its own Envoy-based gateway, and two ingress
controllers competing for ports 80/443 through ServiceLB is a bad time. ServiceLB stays
enabled so that gateway can still get an external IP.

The cluster join token is generated at build time with `SecureRandom.hex(32)`, written to a
gitignored `.k3s-token`, and reused on every later run. It is deliberately **not** hardcoded
in the Vagrantfile — a join token is a credential and this repository is public.

```powershell
# rebuilds the entire cluster from nothing
vagrant destroy -f; vagrant up --no-provision; vagrant provision
```

## Quick start

Requires [Vagrant](https://developer.hashicorp.com/vagrant) 2.4.9+ and the Hyper-V role.
**Every command must run from an elevated PowerShell** — Hyper-V's management API refuses
non-administrators outright, and Vagrant reports that as something else entirely.

Once per host:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\hyperv-create-switch.ps1
```

Then, from the repository:

```powershell
vagrant up --no-provision   # create and boot; each node gains its cluster NIC
vagrant provision           # cluster addresses, then k3s — server first, agents after
vagrant ssh k3s-server
vagrant halt                # power off, keep the VMs
```

Two commands on the first run, one (`vagrant up`) on every run after. The reason is in the
next section.

Each node prints a banner on provision with its OS, CPU flags, interfaces, root size, swap
state and `hrtimer` warning count.

## Networking, and why it takes a script

Vagrant's Hyper-V provider manages **one** network adapter and has no setting for a second.
The cluster needs two, for reasons that do not overlap:

| Adapter | Switch | Role |
|---|---|---|
| `eth0` | **Default Switch** | DHCP and internet, and the address Vagrant SSHes to. Windows re-randomises this subnet on every host reboot, so nothing may depend on it |
| `eth1` | **`k3s-lab`**, an Internal switch | Static `192.168.58.x`. The only address a node is known by |

So `eth1` is attached host-side by
[`scripts/hyperv-attach-cluster-nic.ps1`](scripts/hyperv-attach-cluster-nic.ps1), from an
`after :up` trigger. These boxes are generation 1, which cannot hot-add an adapter, so that
script shuts the VM down, attaches, and starts it again — once, which is why provisioning is
held back to a second command on the first run.

Three details make it work, each one taken from the provider's source rather than guessed:

- **`bridge:` picks the switch by name**, and is set only until Vagrant's `action_configure`
  sentinel exists. Left in place it would be re-applied to *every* adapter on each `up`
  (`Set-VagrantVMSwitch` connects them all), dragging `eth1` onto the Default Switch.
- **SSH follows adapter 0** (`Get-VMNetworkAdapter | Select-Object -Index 0`), so the DHCP
  adapter must stay first and the cluster NIC is appended after it.
- **An Internal switch has no DHCP**, so `eth1` gets its address from a provisioner, with
  `ipv4.never-default yes` to keep the default route on `eth0`.

The trap this replaces is the same on any provider: k3s takes its node IP from the default
route, which points at the adapter Vagrant manages — `10.0.2.15` on every VM under
VirtualBox, a lease that changes under Hyper-V. Both flags are mandatory:

```
--node-ip=192.168.58.x --flannel-iface=eth1
```

The subnet is `192.168.58.0/24` rather than the more usual `.56`, because VirtualBox's
host-only adapter still holds `192.168.56.1` on this host and two interfaces sharing an
address is a routing problem that shows up as intermittent unreachability.

## What goes on top

| Layer | Choice | Why |
|---|---|---|
| Gateway API | v1.4.0+ | The base routing standard |
| [Inference Extension](https://github.com/kubernetes-sigs/gateway-api-inference-extension) | v1.6.2 | `InferencePool` — CRDs that understand LLM traffic |
| Gateway provider | **agentgateway** | kgateway is deprecated; Istio is heavy for 6 GB nodes |
| [llm-d-infra](https://github.com/llm-d-incubation/llm-d-infra) | Helm chart | Deploys the gateway and the endpoint picker |
| Model servers | `llm-d-inference-sim:v0.9.0` | GPU-free stand-in for vLLM |

The **endpoint picker** is the part worth learning. Ordinary Kubernetes load balancing is
round-robin and blind; llm-d's scheduler routes on things that matter for LLMs — which pod
has the relevant KV cache warm, how deep each queue is, which LoRA adapters are loaded.
None of that depends on the workers being real.

Its policy is three weighted scorers, and the weights *are* the design decision:

```yaml
schedulingProfiles:
- name: default
  plugins:
  - pluginRef: prefix-cache-scorer         # weight 3 — cache locality
    weight: 3
  - pluginRef: queue-scorer                # weight 2 — least busy
    weight: 2
  - pluginRef: kv-cache-utilization-scorer # weight 2 — cache headroom
    weight: 2
```

Prefix-cache affinity outranks load balancing 3:2 — llm-d's thesis that a cache hit is worth
more than an evenly distributed queue, expressed as three integers.
[epp-scheduling.md](epp-scheduling.md) has the full walkthrough: the wiring, `failureMode`,
what the payload-agnostic fallback reveals, and how to inspect a distroless EPP.

Using the simulator also removes a prerequisite: the official quickstart needs a HuggingFace
token to pull model weights, and the simulator downloads nothing.

**The simulator is a swap, not a dead end.** The Gateway, HTTPRoute, InferencePool and
metrics pipeline are identical whether the backend is simulated, a local ollama model, or
Claude via Anthropic's API — only one resource changes.
[model-backends.md](model-backends.md) has working YAML for all three, including how the
API key is handled for the hosted case.

### Prefill/decode disaggregation

The two agents are split by role, which is llm-d's **P/D disaggregation** pattern:

| Phase | Work | Bottleneck | Node |
|---|---|---|---|
| **Prefill** | Processes the whole prompt in one parallel pass, producing the KV cache | Compute-bound | `k3s-agent-1` |
| **Decode** | Emits output tokens one at a time, reusing that cache | Memory-bandwidth-bound | `k3s-agent-2` |

Two opposite profiles in one pod means sizing for neither. Split, each scales and is placed
independently — on real hardware, prefill on high-compute accelerators and decode on
high-bandwidth ones. Node labels plus `nodeSelector` pin the pods, so
`kubectl get pods -o wide` shows the architecture directly.

In production the KV cache physically moves between the two, which llm-d does over NIXL.
Here that transfer is **modelled, not real** — the configuration and routing are genuine,
the speedup is not.

## Notes

- **Work from inside the cluster.** No local `kubectl` on the Windows host; `vagrant ssh
  k3s-server` and work there. One less kubeconfig to keep in sync.
- **No distributed storage.** Rook/Ceph was scoped out — three OSDs on one SSD gives no real
  redundancy, and Ceph's default 4 GB `osd_memory_target` would OOM these nodes.
- **Flannel, not OVN-Kubernetes.** OVN-K was considered for OpenShift practice and rejected:
  there is no documented k3s + OVN-K path, and OpenShift never has you install it by hand
  anyway — the Cluster Network Operator does. Hand-rolling the install teaches the one part
  that does not transfer.
- **VM disks belong on an SSD.** Roughly 1000× the random IOPS of a spinning disk, and three
  VMs on one spindle means head thrash.
- **The hypervisor choice was measured, not assumed.** Windows keeps a hypervisor resident
  for Memory Integrity, so VirtualBox never gets AMD-V here and falls back to NEM, where
  guest vCPUs are descheduled for seconds. Sleep 50 ms, 25 times, and compare:

  ```
  VirtualBox (NEM)   multi-second stalls   hrtimer warnings 14/6/6   load 13-19 at 73% idle
  Hyper-V            52 51 52 ... 51 52    hrtimer warnings 0        load 0.03
  ```

  Memory Integrity stays on — Hyper-V *is* the hypervisor it requires, so this removes the
  indirection instead of fighting it. [postmortem-vagrant.md](postmortem-vagrant.md) has the
  full account.
- **One VirtualBox setting cost four hours.** `ioapic=off` silently caps a guest at a single
  CPU while still reporting four. [postmortem-vagrant.md](postmortem-vagrant.md) has the
  full account, including the diagnostics that actually discriminated between "slow" and
  "hung". It no longer applies to the live Vagrantfile, but the reasoning is the transferable
  part.
