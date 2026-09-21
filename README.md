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
disabled, SELinux left **enforcing**.

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

## Notes

- **No storage layer.** Rook/Ceph was scoped out — three OSDs on one SSD gives no real
  redundancy, and Ceph's default 4 GB `osd_memory_target` would OOM these nodes.
- **Flannel, not OVN-Kubernetes.** OVN-K was considered for OpenShift practice and rejected:
  there is no documented k3s + OVN-K path, and OpenShift never has you install it by hand
  anyway — the Cluster Network Operator does. Hand-rolling the install teaches the one part
  that does not transfer.
- **VM disks belong on an SSD.** Roughly 1000× the random IOPS of a spinning disk, and three
  VMs on one spindle means head thrash.
