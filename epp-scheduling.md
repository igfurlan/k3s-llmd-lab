# The Endpoint Picker — how llm-d actually routes

The EPP (Endpoint Picker) is the component that makes llm-d more than a load balancer, and
it is the most interesting thing in this lab. This document records what it does, how it is
wired, and what its default configuration actually contains — read off a running cluster
rather than from documentation.

## Why it exists

A Kubernetes `Service` load-balances blind: round-robin or random across healthy pods. For
LLM traffic that is not merely suboptimal, it is actively wrong in three ways:

1. **Prefix cache locality.** Two requests sharing a prompt prefix should hit the *same* pod,
   because its KV cache is already warm. Round-robin scatters them and every request pays
   full prefill cost.
2. **Queue depth.** A pod with twenty queued requests should not receive a twenty-first while
   a sibling sits idle. Requests are long-lived, so "least connections" matters far more than
   for typical HTTP.
3. **Adapter locality.** A pod with the right LoRA adapter already loaded should be preferred
   over one that would have to load it first.

The EPP knows all three, because it reads the model servers' own metrics.

## How it is wired

The `InferencePool` points at the EPP. From this cluster:

```yaml
spec:
  endpointPickerRef:
    kind: Service
    name: sim-pool-epp
    port: {number: 9002}
    failureMode: FailOpen
  selector:
    matchLabels: {app: sim}     # which pods are candidates
  targetPorts:
    - number: 8000              # where traffic goes
```

Request path:

```
client → gateway :80
         └→ gRPC ext_proc call to sim-pool-epp:9002
            └→ EPP scores every pod matching app=sim
               └→ returns one endpoint
                  └→ gateway forwards to that pod:8000
```

**`failureMode: FailOpen` is worth noticing.** If the EPP dies, the gateway falls back to
ordinary load balancing rather than failing requests. Availability over optimality — so an
EPP outage degrades performance silently instead of causing an incident. Good default,
easy to miss.

The EPP exposes three ports, each with one job:

| Port | Name | Purpose |
|---|---|---|
| 9002 | `grpc` | The ext_proc endpoint the gateway calls |
| 9003 | `grpc-health` | Liveness/readiness |
| 9090 | `metrics` | Prometheus scrape target |

## The scheduling configuration

This is the part worth studying. The EPP is started with
`--config-file /config/default-plugins.yaml`, mounted from a ConfigMap:

```yaml
apiVersion: llm-d.ai/v1alpha1
kind: EndpointPickerConfig
plugins:
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
- name: default
  plugins:
  - pluginRef: queue-scorer
    weight: 2
  - pluginRef: kv-cache-utilization-scorer
    weight: 2
  - pluginRef: prefix-cache-scorer
    weight: 3
```

Three scorers run on every request and their weighted scores are summed; the highest-scoring
endpoint wins.

| Scorer | Weight | Optimises for |
|---|---|---|
| `prefix-cache-scorer` | **3** | Prompt prefix already cached on that pod |
| `queue-scorer` | 2 | Fewer in-flight requests |
| `kv-cache-utilization-scorer` | 2 | KV cache not near capacity |

**The weights are the policy.** Prefix-cache affinity outranks load balancing 3:2 — llm-d's
opinion, expressed as three integers, that a cache hit is worth more than an evenly
distributed queue. Changing these numbers changes the system's whole character, and they are
the first thing to experiment with.

`metrics-data-source` is how the EPP learns pod state: it scrapes `/metrics` on each model
server. That is precisely why a simulated backend works here — `llm-d-inference-sim` emits
vLLM-compatible metrics, so the scheduler cannot tell the difference.

## Finding: the default config has no prefill/decode profile

There is exactly **one** scheduling profile, named `default`, and no `disagg-profile-handler`
plugin. So out of the box the EPP treats every pod in the pool as interchangeable.

This resolves a question the documentation left ambiguous. llm-d's GitHub guide describes two
InferencePools for P/D; the llm-d.ai docs describe one pool with two labelled Deployments.
The running cluster settles it:

- **One `InferencePool`**, selecting both roles via `app: sim`
- **Two Deployments**, labelled `llm-d.ai/role=prefill` and `llm-d.ai/role=decode`
- **P/D is an EPP configuration concern**, not a pool-topology one

Until the EPP config carries a disagg profile, those role labels are inert — correct, and
required later, but nothing reads them yet.

The lever is documented inside the ConfigMap's own second entry:

```
Select it by setting router.epp.pluginsConfigFile: payload-agnostic.yaml
```

So `router.epp.pluginsConfigFile` is the Helm value that chooses which config the EPP loads.
Supplying a custom `EndpointPickerConfig` with prefill/decode profiles is the path to real
P/D scheduling.

## The second config: payload-agnostic

The chart ships a fallback worth understanding, because it shows what the scorers depend on:

```yaml
plugins:
- type: passthrough-parser
- type: active-request-scorer
- type: session-affinity-scorer
requestHandler:
  parsers:
  - pluginRef: passthrough-parser
schedulingProfiles:
- name: default
  plugins:
  - pluginRef: active-request-scorer
    weight: 1
  - pluginRef: session-affinity-scorer
    weight: 1
```

Its own comment explains the trade-off: when the request format is unknown, the EPP cannot
parse the body, so **the prefix-cache scorer becomes impossible** — you cannot hash a prefix
you cannot read. Routing falls back to backend state only: least-busy, plus session affinity
to keep a conversation pinned to one pod.

That is a good illustration of why an inference gateway must understand the payload. Strip
that away and it degrades to a slightly smarter load balancer.

## Inspecting it on a live cluster

**The EPP image is distroless** — no shell, no `cat`, no `curl`. `kubectl exec` into it fails:

```
OCI runtime exec failed: exec: "cat": executable file not found in $PATH
```

Read the config from the ConfigMap instead:

```bash
kubectl get configmap sim-pool-epp -n llm-d -o yaml
```

And reach the metrics via the Service ClusterIP from a node, or a throwaway curl pod:

```bash
kubectl run m --rm --attach --restart=Never --image=curlimages/curl -n llm-d -- \
  curl -s http://sim-pool-epp:9090/metrics
```

Other useful views:

```bash
kubectl describe inferencepool sim-pool -n llm-d
kubectl logs -n llm-d deploy/sim-pool-epp --tail=40
kubectl get pods -n llm-d -o wide -L llm-d.ai/role
```

**Open item:** on this cluster `/metrics` returns an empty body. GAIE's EPP commonly requires
a bearer token on that endpoint, so the next step is checking the status code with `curl -i`
rather than assuming the metrics are absent.
