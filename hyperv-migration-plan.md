# Migration plan — VirtualBox → Hyper-V

**Status:** not started. Written 2026-09-22 as a handoff, after the measurement below
settled the question.

---

## Why

VirtualBox has **no hardware virtualization** on this host. Windows keeps a hypervisor
resident for Memory Integrity (HVCI), so VirtualBox falls back to NEM — the Windows
Hypervisor Platform API:

```
HM: HMR3Init: Attempting fall back to NEM: AMD-V is not available
```

The consequence is that guest vCPUs are descheduled for **seconds at a time**. A 50 ms
sleep, 50 consecutive samples, same host:

| | VirtualBox (NEM) | Hyper-V (native) |
|---|---|---|
| `sleep 0.05` actual | multi-second stalls | **51–52 ms, every sample** |
| `dmesg \| grep -c hrtimer` | 14 server / 6 per agent | **0** |
| Jitter | unbounded | ±1 ms |

`hrtimer: interrupt took 3249948 ns` — a timer interrupt taking 3.2 seconds — is the guest
kernel reporting that it was not running.

Everything that went wrong downstream traces to this: containerd RPCs hitting
`DeadlineExceeded`, PLEG going stale, nodes flapping NotReady, load average 42 with 73% idle
CPU and 0% iowait, metrics-server burning 90% of a vCPU failing its own scrapes, and finally
a control plane that could not complete startup in 19 minutes.

**Memory Integrity stays enabled.** Hyper-V *is* the hypervisor HVCI requires, so running VMs
on it directly removes the indirection rather than fighting it. The Hyper-V role is already
installed on this host (`vmms` Running/Automatic, PowerShell module present) — no new Windows
configuration is needed.

---

## What carries over unchanged

Roughly two thirds of the work, including everything that was hard to find:

- **k3s configuration design.** Settings live in `/etc/rancher/k3s/config.yaml`, not in
  `INSTALL_K3S_EXEC`. k3s re-reads it on every start, so the Vagrantfile stays authoritative
  for an existing cluster; baked-in installer flags can never change after first install.
- **`--node-ip` and `--flannel-iface=eth1` are mandatory.** Every Vagrant VM has a NAT
  adapter at the same `10.0.2.15`; without these all nodes register under one address and pod
  networking breaks in ways that look like anything but networking. **Re-verify the interface
  names on `generic/rocky9`** — they may not be `eth0`/`eth1`.
- **Join token** generated with `SecureRandom.hex(32)` into a gitignored `.k3s-token`.
- **`--disable=traefik`** (llm-d brings its own gateway) and **`--disable=metrics-server`**
  (pathological on a slow host; re-evaluate once Hyper-V is in — it may be fine again).
- The entire llm-d stack and its version pins (below).
- All documentation: `README.md`, `plan.html`, `postmortem-vagrant.md`,
  `epp-scheduling.md`, `model-backends.md`.

## What gets rebuilt

| Layer | Change |
|---|---|
| Box | `rockylinux/9` v5.0.0 → **`generic/rocky9` v4.3.12** (the only Rocky box publishing a `hyperv` provider) |
| Provider block | Drop `--ioapic` and `--paravirtprovider` — both are VirtualBox `modifyvm` calls and Hyper-V needs neither |
| `boot_timeout` | 1800 was compensation for NEM; can likely return to the default |
| Kernel pin | `dnf update --exclude=kernel*` existed only because of the vCPU bug. **Remove it and test** |
| Data disk | `config.vm.disk` is VirtualBox-only. Needs a Hyper-V VHDX equivalent |
| `CLUSTER_NET` switch | VirtualBox-specific (`virtualbox__intnet`). Rework or drop |
| **Networking** | The real work — see below |

---

## Research first, write second

Three things to verify before writing any Vagrantfile. Guessing at these is what cost the
last two days.

### 1. Two network adapters

We need what VirtualBox gave us for free: **NAT for internet** plus a **stable cluster
network** at `192.168.56.x`. Vagrant's Hyper-V provider is materially less capable than its
VirtualBox one and historically attaches only **one** adapter.

Likely shape:
- Adapter 1: Hyper-V **Default Switch** (NAT, internet, dynamic IP — fine, we don't route on it)
- Adapter 2: a host **Internal switch** created once with
  `New-VMSwitch -Name k3s-lab -SwitchType Internal`, host side given `192.168.56.1/24`,
  guests assigned static `192.168.56.11-13` by a provisioner

Open: whether Vagrant can attach the second adapter declaratively, or whether it needs a
`config.trigger.after :up` calling `Add-VMNetworkAdapter` on the host. **Verify before
writing.**

### 2. Extra disk

`config.vm.disk` will not work. Options: a trigger calling `New-VHD` + `Add-VMHardDiskDrive`,
or dropping the second disk if `generic/rocky9`'s root is large enough. Check its root size
first — `rockylinux/9` shipped 8.9 GB, which was the reason for the disk.

### 3. Elevation

Every `vagrant` command needs an **elevated PowerShell** under Hyper-V. Worth a line in the
README so a reader is not confused.

---

## Execution order

1. **Research** the three items above. Do not write the Vagrantfile first.
2. `vagrant destroy -f` the VirtualBox VMs; keep `.k3s-token`.
3. Create the Internal switch on the host (one-time, admin).
4. Write the new Vagrantfile. Keep `NODES`, the token block, `PREREQS`, `STORAGE` (adapted),
   `K3S_SERVER`, `k3s_agent` — only the provider and network blocks are new.
5. `vagrant up`, verify: `nproc` = 4, interface names, `192.168.56.x` reachable node-to-node,
   swap 0, SELinux enforcing, **`dmesg | grep -c hrtimer` = 0**.
6. Re-run the llm-d install sequence (below).
7. **Apply the P/D decider config** — the one thing we never got to test.
8. Update `postmortem-vagrant.md` with the migration and the measurement that justified it.
9. Remove the kernel pin and confirm a current kernel boots.

---

## Reference: version pins

| Component | Version | Notes |
|---|---|---|
| Box | `generic/rocky9` `4.3.12` | has `hyperv` provider |
| k3s | `v1.36.4+k3s1` | stable channel |
| Gateway API | `v1.6.2` | `standard-install.yaml` |
| Gateway API Inference Extension | `v1.6.2` | `v1-manifests.yaml` — ships **only** `inferencepools` CRD |
| agentgateway | `v1.5.0` | **not v1.1.0** — it watches `v1alpha2.TCPRoute`, which Gateway API 1.6.2 no longer serves, so its informer blocks forever and the GatewayClass is never registered |
| llm-d router chart | `oci://ghcr.io/llm-d/charts/llm-d-router-gateway` `v0.10.0` | **not** `llm-d-modelservice`, which is deprecated |
| EPP image | `ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.10.0` | |
| Simulator | `ghcr.io/llm-d/llm-d-inference-sim:v0.11.2` | |
| helm | 3.22.0 | installed on the server node |

## Reference: llm-d install sequence

All on `k3s-server`, with `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml` and
`export PATH=$PATH:/usr/local/bin`.

```bash
# 1. helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 2. Gateway API CRDs
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml

# 3. Inference Extension CRDs — BEFORE agentgateway, never after
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.6.2/v1-manifests.yaml
kubectl get crd | grep inference     # must list inferencepools

# 4. agentgateway
AGENTGATEWAY_VERSION=v1.5.0
helm upgrade --install agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --namespace agentgateway-system --create-namespace --version ${AGENTGATEWAY_VERSION}
helm upgrade --install agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system --version ${AGENTGATEWAY_VERSION} \
  --set inferenceExtension.enabled=true
kubectl get gatewayclass                 # agentgateway, ACCEPTED=True

# 5. simulator deployments, split by role
kubectl create namespace llm-d
kubectl label node k3s-agent-1 llm-d.ai/role=prefill --overwrite
kubectl label node k3s-agent-2 llm-d.ai/role=decode --overwrite
# two Deployments: sim-prefill / sim-decode, both labelled app=sim plus
# llm-d.ai/role=<role>, each with a matching nodeSelector, image v0.11.2,
# args ["--model","meta-llama/Llama-3.1-8B-Instruct","--port","8000"]

# 6. Gateway
#   kind: Gateway, name inference-gateway, ns llm-d, gatewayClassName agentgateway,
#   one HTTP listener on port 80

# 7. InferencePool + EPP
helm upgrade -i sim-pool oci://ghcr.io/llm-d/charts/llm-d-router-gateway \
  --version v0.10.0 --namespace llm-d \
  --set router.modelServers.matchLabels.app=sim \
  --set router.epp.resources.requests.cpu=100m \
  --set router.epp.resources.requests.memory=128Mi \
  --set router.epp.resources.limits.memory=512Mi \
  --set provider.name=none \
  --set httpRoute.create=true \
  --set httpRoute.inferenceGatewayName=inference-gateway

# 8. smoke test
cat > /tmp/req.json <<'EOF'
{"model":"meta-llama/Llama-3.1-8B-Instruct","messages":[{"role":"user","content":"hello there"}]}
EOF
curl -s http://192.168.56.11/v1/chat/completions -H 'Content-Type: application/json' -d @/tmp/req.json
```

`provider.name=none` matters: agentgateway handles the InferencePool natively, so the chart
must not deploy its own proxy.

## Reference: the P/D config we never got to test

Verified to load (the EPP accepted every plugin name), but P/D stayed **disabled** because no
decider was configured:

```
disagg/disagg_profile_handler.go:172  "No deciders.prefill configured, P/D disaggregation disabled"
```

The fix, untested:

```yaml
router:
  epp:
    pluginsConfigFile: "pd-plugins.yaml"
    flags:
      allow-experimental-plugins: true
    pluginsCustomConfig:
      pd-plugins.yaml: |
        apiVersion: llm-d.ai/v1alpha1
        kind: EndpointPickerConfig
        plugins:
        - type: prefix-based-pd-decider
          parameters:
            nonCachedTokens: 1        # 0 = disabled (the default). 1 = always split.
        - type: disagg-profile-handler
          parameters:
            deciders:
              prefill: prefix-based-pd-decider
        - type: prefill-filter
        - type: decode-filter
        - type: queue-scorer
        - type: kv-cache-utilization-scorer
        - type: prefix-cache-scorer
        - type: metrics-data-source
          parameters:
            scheme: "http"
            path: "/metrics"
            insecureSkipVerify: true
        - type: core-metrics-extractor
        schedulingProfiles:
        - name: prefill
          plugins:
          - pluginRef: prefill-filter
          - pluginRef: prefix-cache-scorer
            weight: 3
          - pluginRef: queue-scorer
            weight: 1
        - name: decode
          plugins:
          - pluginRef: decode-filter
          - pluginRef: queue-scorer
            weight: 3
          - pluginRef: kv-cache-utilization-scorer
            weight: 2
```

Confirm success in the EPP log's `EPP config after phase two` line: it should read
`ProfileHandler: disagg-profile-handler` with both profiles, and **must not** repeat the
"No deciders.prefill configured" message.

---

## Gotchas that will bite again

- **`/usr/local/bin` is not on the PATH in a Vagrant provisioner** (nor under `sudo`'s
  `secure_path`). Call `k3s`, `helm` and `kubectl` by absolute path in scripts.
- **The EPP image is distroless** — no shell, no `cat`, no `curl`. Read its config from the
  ConfigMap and its metrics via a throwaway curl pod or the Service ClusterIP.
- **EPP `/metrics` requires auth** (`metrics-endpoint-auth: true` in its flags). An empty
  response is not an absent metric.
- **Never run a display command unguarded at the end of a provisioner.** Under
  `set -euo pipefail` a transient failure aborts the whole multi-machine run and later nodes
  are silently skipped.
- **Check `helm template … | grep apiVersion` before installing a chart** against CRDs of a
  different version. That check proved llm-d's GAIE v1.5.0 pin was harmless against our
  v1.6.2 CRDs, and would have caught the agentgateway mismatch an hour earlier.
- **Verify a box artifact exists before pinning it.** `rockylinux/9` v6.0.0 is listed
  `active` but its `.box` 404s. Range-GET it: expect HTTP 206.
