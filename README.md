# k3s-llmd-lab

A three-node [k3s](https://k3s.io) cluster on a Windows desktop, running the
[llm-d](https://llm-d.ai) distributed inference stack end to end: Gateway API with the
Inference Extension, an endpoint picker that routes on KV-cache state, prefill/decode
disaggregation, a real model alongside simulated ones, and Prometheus and Grafana watching
all of it.

Everything here was measured on the cluster rather than taken from documentation, and the
measurements that contradicted expectations are written down too.

---

## What this lab found

**Prefix-aware routing beat round-robin by 4.2 points on identical traffic — 82.6% against
78.4% cache hit ratio — and cost 2.5× the latency to do it.**
Against the theoretical ceiling (86.4%, set by 64-token block granularity) that is capturing
96% of the achievable versus 91%: round-robin recomputes about a quarter more prompt tokens.
The latency cost is real and is a property of *this* hardware, where a simulated prefill is
nearly free. [The experiment →](bench/)

**The first version of that experiment found nothing, and the reason is the more useful
half.** Both arms scored 74%, which turned out to be exactly `192/259` — the shared system
prompt and nothing else. Per-user context was 40 tokens, under the 64-token block size, so it
could never be cached wherever it was routed; the cache held 65,536 tokens so nothing ever
evicted; and with one pod per role the picker logged `num-of-candidates: 1`, meaning there
was no routing decision to make at all. **Cache-aware routing needs distinguishing prefixes
that span whole blocks, memory scarce enough to evict, and more than one candidate.** Absent
those, round-robin ties and wins on latency.

**Prefill/decode disaggregation was "enabled" for a day while doing nothing.** Every plugin
loaded, the EPP logged both scheduling profiles, and no traffic was ever split — because the
component that acts on the routing decision, a proxy sidecar in front of the decode server,
was missing. The only evidence was a counter that did not exist on one pod.
[How it was found →](docs/epp-scheduling.md#configured-is-not-operating)

**Smart routing costs 95 µs against a 23.8 ms time-to-first-token** — about 0.4% of the
request. That ratio, not the absolute number, is what justifies putting a scheduler in the
request path.

**Two days were lost to a hypervisor, not to Kubernetes.** VirtualBox never gets AMD-V on
this host because Windows holds the hypervisor for Memory Integrity, so guests ran on NEM and
were descheduled for seconds at a time. A 50 ms sleep, 25 samples: multi-second stalls on
VirtualBox against a flat `51 51 51 … 50 51` on Hyper-V; `hrtimer` warnings 14/6/6 against 0;
load average 13–19 at 73% idle CPU against 0.03. [The postmortem →](docs/postmortem-vagrant.md)

---

## Architecture

```
  curl ──▶ Gateway (agentgateway, :80)
             │
             ├─ /v1/chat/completions ──▶ ext_proc ──▶ Endpoint Picker (EPP)
             │                                          │  scores every pod in the
             │                                          │  InferencePool, then answers
             │                                          │  with one — or two, on a split
             │                                          ▼
             │                              ┌────────────────────────┐
             │                              │ prefill × 3   (agent-1)│ compute-bound
             │                              │ decode  × 3   (agent-2)│ bandwidth-bound
             │                              └────────────────────────┘
             │                                 decode's sidecar fetches the prefill
             │                                 and the KV cache moves between them
             │
             ├─ /rr/v1/chat/completions ─▶ plain Service (round-robin)   ← the control arm
             │
             └─ /ollama/v1/...          ─▶ ollama, qwen2.5:0.5b          ← real inference
```

| Component | Version | Role |
|---|---|---|
| k3s | `v1.36.4+k3s1` | 1 server + 2 agents, Flannel, traefik disabled |
| Gateway API | `v1.6.2` | The routing standard |
| [Inference Extension](https://github.com/kubernetes-sigs/gateway-api-inference-extension) | `v1.6.2` | `InferencePool` — CRDs that understand LLM traffic |
| [agentgateway](https://agentgateway.dev) | `v1.5.0` | Gateway implementation. **Not v1.1.0** — it watches a `v1alpha2.TCPRoute` that Gateway API 1.6.2 no longer serves, so its informer blocks forever and the GatewayClass never registers |
| llm-d router | `v0.10.0` | Endpoint picker + the P/D routing sidecar |
| [llm-d-inference-sim](https://github.com/llm-d/llm-d-inference-sim) | `v0.11.2` | GPU-free vLLM stand-in, emitting vLLM's metric names |
| vLLM (render) | `v0.21.0` | Tokenizer only — no weights, no GPU |
| ollama | `0.34.3` | Real inference, `qwen2.5:0.5b` |
| kube-prometheus-stack | latest | Prometheus + Grafana, trimmed for 6 GB nodes |

---

## What is real and what is simulated

The model servers are simulators. **They emit vLLM's own metric names**, so the gateway, the
scheduler, the cache accounting and every dashboard panel behave exactly as they would
against real vLLM — swap the image and nothing else changes. Only the tensor math is absent.

ollama runs a real model on the same gateway, at `/ollama`, which is what the CPU and memory
panels contrast: a real model burning cores beside simulators that do not.

**What this lab can prove:** that the scheduler controls where requests go, how often caches
hit, and what that costs in scheduling latency.
**What it cannot:** what a cache hit is worth in wall-clock seconds. That needs real weights
on real accelerators, and any latency number here is a property of the simulator's
configuration.

One assumption worth retiring: the lab was designed around "vLLM's CPU backend needs AVX-512
and the guests don't have it", measured under VirtualBox. Under Hyper-V the same host passes
the full set through — `avx512f avx512bw avx512dq avx512vl avx512_bf16 avx512_vnni` — so that
constraint belonged to the hypervisor, not the hardware. Only 6 GB nodes keep real vLLM out
now.

---

## Running it

Requires [Vagrant](https://developer.hashicorp.com/vagrant) 2.4.9+ and the Hyper-V role.
**Every command needs an elevated PowerShell** — Hyper-V's management API refuses
non-administrators, and Vagrant reports that as something else entirely.

```powershell
# once per host: creates the Internal switch the cluster network lives on
powershell -ExecutionPolicy Bypass -File scripts\hyperv-create-switch.ps1

vagrant up --no-provision   # create and boot; each node gains its cluster NIC
vagrant provision           # cluster addresses, then k3s — server first, agents after
```

Two commands on the first run, one (`vagrant up`) afterwards — the reason is in
[Networking](#networking-and-why-it-takes-a-script). Then the llm-d stack, in order, from
[`manifests/`](manifests/).

Grafana lands on `http://192.168.58.11:30300`.

### Cluster

| Node | Role | Cluster IP | vCPU | RAM |
|---|---|---|---|---|
| `k3s-server` | control plane, tokenizer, monitoring | `192.168.58.11` | 4 | 6144 MB |
| `k3s-agent-1` | prefill × 3 | `192.168.58.12` | 4 | 6144 MB |
| `k3s-agent-2` | decode × 3, ollama | `192.168.58.13` | 4 | 6144 MB |

Rocky Linux 9 from `generic/rocky9` (the only Rocky box publishing a `hyperv` provider).
Swap off, firewalld disabled, **SELinux enforcing** — k3s installs `k3s-selinux` itself,
which is the posture a real RHEL deployment would have. Memory is fixed rather than dynamic:
the box's own Vagrantfile sets `maxmemory = 2048`, and any `maxmemory` enables Hyper-V
Dynamic Memory, which would cap a 6 GB node at 2 GB.

k3s settings live in `/etc/rancher/k3s/config.yaml`, not in `INSTALL_K3S_EXEC` — the
Vagrantfile skips installation when k3s is already running, so anything baked into the
installer could never change again. The join token is generated with `SecureRandom.hex(32)`
into a gitignored file, never hardcoded: it is a credential and this repository is public.

---

## Networking, and why it takes a script

Vagrant's Hyper-V provider manages **one** network adapter. The cluster needs two:

| Adapter | Switch | Role |
|---|---|---|
| `eth0` | **Default Switch** | DHCP, internet, and the address Vagrant SSHes to. Windows re-randomises this subnet on every host reboot, so nothing may depend on it |
| `eth1` | **`k3s-lab`**, Internal | Static `192.168.58.x` — the only address k3s is told about |

A node's IP is its *identity*: kubelet registration, flannel's tunnel endpoints, the server's
TLS SANs and the agents' join URL all key on it. Pin it to a DHCP lease and the cluster works
until the next host reboot, then fails as a certificate error, a join failure and broken pod
networking at once — none of which says "your IP changed".

So `eth1` is attached host-side by a trigger script. Three details make it work, each read
from the provider's source rather than guessed:

- **`bridge:` selects the switch by name**, and is set only until Vagrant's `action_configure`
  sentinel exists — left in place it is re-applied to *every* adapter on each `up`, dragging
  the cluster NIC onto the Default Switch.
- **SSH follows adapter 0**, so the DHCP adapter must stay first.
- **An Internal switch has no DHCP**, so the address is assigned by a provisioner with
  `ipv4.never-default yes`, keeping the default route on `eth0`.

These boxes are generation 1 and cannot hot-add a NIC, which is why the first run shuts each
VM down, attaches, and starts it again — and why provisioning waits for the second command.

---

## Repository map

| Path | What is in it |
|---|---|
| [`Vagrantfile`](Vagrantfile) | The whole cluster: 3 VMs, two networks, k3s, all of it |
| [`scripts/`](scripts/) | Host-side PowerShell: create the switch, attach the cluster NIC |
| [`manifests/`](manifests/) | Gateway, simulators, tokenizer, ollama, the round-robin control arm |
| [`manifests/monitoring/`](manifests/monitoring/) | Prometheus stack values, scrape config, dashboard JSON |
| [`bench/`](bench/) | The A/B experiment: load generator, protocol, results |
| [`docs/`](docs/) | The deep dives |
| [`archive/`](archive/) | The VirtualBox Vagrantfile, kept with a header on why it was abandoned |

### Deep dives

| Document | What it covers |
|---|---|
| [reading-the-dashboard.md](docs/reading-the-dashboard.md) | **Each panel mapped to the decision it drives** — which weight to change, when to stop disaggregating, why replicas cannot fix a distribution fault |
| [epp-scheduling.md](docs/epp-scheduling.md) | The endpoint picker: profiles, weighted scorers, the P/D decider's arithmetic, and how "enabled" was not "operating" |
| [postmortem-vagrant.md](docs/postmortem-vagrant.md) | Four wrong hypotheses, one `ioapic=off`, and the measurement that ended it |
| [hyperv-migration-plan.md](docs/hyperv-migration-plan.md) | The migration, researched from provider source before a line was written |
| [model-backends.md](docs/model-backends.md) | Swapping the simulator for ollama or a hosted model |
| [bench/README.md](bench/README.md) | The A/B experiment, both runs, including the null result |

---

## Observability

Prometheus scrapes the simulators through a `PodMonitor` and the endpoint picker through an
authenticated `ServiceMonitor`. The EPP's `/metrics` is guarded by `--metrics-endpoint-auth`,
and an unauthenticated request returns an **empty 200** rather than a 401 — which reads
exactly like a component that exports nothing. Authentication was kept on and Prometheus
given a token, rather than the reverse.

That token was rejected for a while too, for a reason worth knowing: the EPP could not
*check* it. Controller-runtime validates bearer tokens with a `TokenReview` and a
`SubjectAccessReview`, and the chart enables metrics auth without granting the EPP those
rights. Binding `system:auth-delegator` fixes the checker, not the credential.

Dashboard JSON lives in [`manifests/monitoring/dashboards/`](manifests/monitoring/dashboards/)
and provisions from a ConfigMap, so Grafana deliberately has no persistence — the UI is never
the only copy.

---

## Scope

Deliberately out: Rook/Ceph (three OSDs on one SSD is not redundancy), OVN-Kubernetes (no
documented k3s path, and OpenShift installs it via an operator anyway), and Ansible (the
Vagrantfile already provisions; a second configuration tool would be ceremony).

The interesting thread left unexplored is **precise prefix-cache routing** — the simulators
already publish `BlockStored` events over ZMQ, and consuming them would replace the router's
block-rounded estimate with each pod's actual cache contents.
