# k3s-llmd-lab

A three-node [k3s](https://k3s.io) cluster on VirtualBox, built to run the
[llm-d](https://llm-d.ai) distributed inference stack — provisioned from a single
Vagrantfile, on a Windows host.

The GPU in the host machine is unreachable from the VMs, so **the inference is simulated
and the orchestration is real**. That trade is deliberate, and explained below.

## Why simulated inference

Three independent facts, any one of which is disqualifying on its own:

1. **VirtualBox has no GPU passthrough.** The host's RTX 5070 Ti is invisible to every guest.
2. **vLLM's CPU backend requires AVX-512.** The host CPU has it; VirtualBox does not expose it
   to guests. Measured in the running VMs: `avx avx2`, nothing beyond.
3. **Hyper-V compatibility mode compounds it.** Windows keeps a hypervisor resident, costing
   nested paging and sometimes AVX2 itself.

The resolution is [`llm-d-inference-sim`](https://github.com/llm-d/llm-d-inference-sim) — the
llm-d project's own GPU-free vLLM mock. It is OpenAI-API compliant, models prefill and decode
latency, degrades under concurrency, and emits vLLM-compatible Prometheus metrics. The gateway,
the scheduler, the routing layer and the entire observability story exercise identically. Only
the tensor math is fake.

Real inference comes from [ollama](https://ollama.com), which is built for CPU and gets its
AVX2 fast path.

## Cluster

| Node | Role | Host-only IP | vCPU | RAM |
|---|---|---|---|---|
| `k3s-server` | control plane + workload | `192.168.56.11` | 4 | 6144 MB |
| `k3s-agent-1` | workload | `192.168.56.12` | 4 | 6144 MB |
| `k3s-agent-2` | workload | `192.168.56.13` | 4 | 6144 MB |

Guests are Rocky Linux 9, from box `rockylinux/9` pinned at `5.0.0`. Swap off, firewalld
disabled, SELinux left **enforcing** — k3s installs `k3s-selinux` and `container-selinux`
itself, which is the same posture a real RHEL deployment would have.

Each node carries a **30 GB second disk mounted at `/var/lib/rancher`**. The box's root
filesystem is 8.9 GB, and containerd images, local-path volumes and a model will not fit in
what remains. The disk is dynamically allocated, so unused space costs nothing on the host.

### k3s

Installed by the Vagrantfile, pinned to `v1.36.4+k3s1`:

```
--node-ip=192.168.56.11 --flannel-iface=eth1 --tls-san=192.168.56.11
--disable=traefik --write-kubeconfig-mode=0644
```

`--disable=traefik` because llm-d brings its own Envoy-based gateway, and two ingress
controllers competing for ports 80/443 through ServiceLB is a bad time. ServiceLB stays
enabled so that gateway can still get an external IP.

The cluster join token is generated at build time with `SecureRandom.hex(32)`, written to a
gitignored `.k3s-token`, and reused on every later run. It is deliberately **not** hardcoded
in the Vagrantfile — a join token is a credential and this repository is public.

```bash
vagrant destroy -f && vagrant up   # rebuilds the entire cluster from nothing
```

## Quick start

Requires [Vagrant](https://developer.hashicorp.com/vagrant) 2.4.9+ and
[VirtualBox](https://www.virtualbox.org) 7.2.x.

```bash
vagrant up          # build and provision all three nodes
vagrant ssh k3s-server
vagrant halt        # power off, keep the VMs
```

Each node prints a banner on provision with its OS, CPU flags, interfaces and swap state.

## The networking trap

Every Vagrant VM has **two** adapters: `eth0` is NAT at `10.0.2.15` — *identical on all three
machines* — and `eth1` carries the host-only address that actually routes between nodes.

k3s auto-detects its node IP from the default route, which points at the NAT adapter. Left
alone, all three nodes register as `10.0.2.15`, the cluster forms, and pod networking breaks
silently. Both flags are mandatory:

```
--node-ip=192.168.56.x --flannel-iface=eth1
```

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
- **The host has no AMD-V available.** Windows keeps a hypervisor resident, so VirtualBox
  falls back to NEM (the Windows Hypervisor Platform API) and every VM exit is expensive.
  This is the performance baseline everything here runs on, and it is why `boot_timeout` is
  set to 1800 rather than the default.
- **One VirtualBox setting cost four hours.** `ioapic=off` silently caps a guest at a single
  CPU while still reporting four. [postmortem-vagrant.md](postmortem-vagrant.md) has the
  full account, including the diagnostics that actually discriminated between "slow" and
  "hung".
