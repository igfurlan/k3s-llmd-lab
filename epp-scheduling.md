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

---

## Prefill/decode disaggregation — enabled in the scheduler (2026-09-23)

> **Scope:** this section is about the *scheduler*. The EPP now decides to split every
> request and names both pods. The split does **not** yet reach the data path — see
> [Configured is not operating](#configured-is-not-operating) at the end.

On the VirtualBox cluster every plugin name below loaded and P/D still stayed off, because
nothing was driving the plugins:

```
disagg/disagg_profile_handler.go:172  "No deciders.prefill configured, P/D disaggregation disabled"
```

The missing piece was one parameter — `deciders.prefill` on the profile handler, naming a
decider plugin. The full values file is [manifests/epp-pd-values.yaml](manifests/epp-pd-values.yaml);
the part that matters:

```yaml
- type: prefix-based-pd-decider
  parameters:
    nonCachedTokens: 1        # 0 = disabled (the default). 1 = always split.
- type: disagg-profile-handler
  parameters:
    deciders:
      prefill: prefix-based-pd-decider
```

`nonCachedTokens` is the threshold: a request is split only when it has at least this many
tokens that no pod has cached. The default `0` disables the split entirely, which is the
trap — the plugin is loaded, configured and inert. `1` means "always split", which is what a
lab wants: the behaviour becomes observable on every request rather than only on long
prompts.

Confirmation is in the EPP's own startup log, `EPP config after phase two`:

```
ProfileHandler: disagg-profile-handler/disagg-profile-handler
Profiles: map[
  decode:  {Filters: [decode-filter/by-label],
            Scorers: [queue-scorer: 3.0, kv-cache-utilization-scorer: 2.0],
            Picker: max-score-picker}
  prefill: {Filters: [prefill-filter/by-label],
            Scorers: [prefix-cache-scorer: 3.0, queue-scorer: 1.0],
            Picker: max-score-picker}]
```

### Three things that log reveals

**A decoy message.** `No deciders.encode configured, E disaggregation disabled` appears right
next to the success. That is *encode* — a third stage for multimodal inputs — not prefill.
Reading it as a failure costs an afternoon.

**The EPP wires its own data layer.** It logs
`auto-created default producer: token-producer → TokenizedPrompt → consumer: disagg-profile-handler`.
The decider counts tokens, so the EPP instantiated a tokenizer and connected it without being
asked. That line is better proof that the decider is *live* than the config dump is, since a
parsed-but-unused plugin would not need a producer.

**System defaults fill the gaps.** `max-score-picker` is appended to both profiles — scorers
only produce numbers, and a picker is what turns them into a choice — along with
`openai-parser`, `anthropic-parser` and `vllmhttp-parser`. That parser list is why pointing
this pool at a real Anthropic backend is a configuration change rather than a rewrite; see
[model-backends.md](model-backends.md).

### Why the weights differ between profiles

| Profile | Weights | Reasoning |
|---|---|---|
| **prefill** | `prefix-cache-scorer` 3, `queue-scorer` 1 | A pod that already holds this prefix skips the expensive pass entirely. Cache locality is worth more than an even queue — 3:1 |
| **decode** | `queue-scorer` 3, `kv-cache-utilization-scorer` 2 | Decode work is long-lived and bandwidth-bound. Locality no longer helps; free capacity does |

Same cluster, same plugins, opposite priorities — which is the argument for splitting the
phases stated as six integers.

---

## Configured is not operating

The EPP's startup log said P/D was on. The cluster disagreed, and the metrics said so
plainly. After three identical requests:

| Pod | `prefix_cache_hits_total` | `prefix_cache_queries_total` |
|---|---|---|
| `sim-decode` | 128 | 306 |
| `sim-prefill` | **metric absent** | **metric absent** |

A counter that has never incremented is not exported at all, so "absent" here means zero
requests — not zero hits. Every request went to decode, which did its own prefill locally.
The scheduler was splitting; nothing downstream acted on the split.

### Why

The EPP does not send the request to the prefill pod. It names that pod in a header and
expects something else to act on it. From
[llm-d-routing-sidecar](https://github.com/llm-d/llm-d-routing-sidecar):

> This project provides a reverse proxy redirecting incoming requests to the prefill worker
> specified in the `x-prefiller-host-port` HTTP request header.

That proxy — now `pd-sidecar`, in the `llm-d-router` repository, published as
`ghcr.io/llm-d/llm-d-router-disagg-sidecar` — runs **in front of the decode model server**.
It reads the header, drives the prefill worker, arranges the KV transfer, then hands the
request to the local server for decode. Without it, the header reaches a model server that
has no idea what it means, and is ignored.

So the deployment is missing a component, not misconfigured. Both observations were true at
once: the scheduler *was* disaggregating, and the cluster *was not*.

### The lesson, which is the same one as the boot hang

Every layer reported success. The Helm release was deployed, the EPP logged both profiles,
the pods were Ready, and requests returned valid completions with correct token counts. The
only thing that contradicted the story was a counter that did not exist on one pod.

Confirming a control plane is not confirming a data path. A feature that is configured,
loaded and logged can still be doing nothing, and the way to tell the difference is always
the same: find a number that only moves if the work actually happened, and look at it.

### Next increment

Add the `pd-sidecar` container to `sim-decode`, fronting the simulator: the sidecar takes
port 8000 (the InferencePool's target), the simulator moves behind it. One consequence to
remember — the EPP's `metrics-data-source` then scrapes the sidecar's port rather than the
model server's, which is what the plugin's optional `port` parameter exists for.

---

## P/D in the data path, and the arithmetic behind a split

Adding `ghcr.io/llm-d/llm-d-router-disagg-sidecar` to the decode pod closed the gap. The
sidecar takes the InferencePool's target port (8000) and the simulator moves behind it
(8200); everything the sidecar does not handle itself is proxied straight through, `/metrics`
included, so the EPP's scrape needs no reconfiguration.

Proof it reached the data path — `sim-prefill` logging a request for the first time:

```
http.go:283  "Received" new HTTP="chat completion request (req id 322c8bc9...)"
worker.go:74 "Finished processing request"
```

Only **prefill** is fronted by nothing and **decode** is fronted by the sidecar. That
asymmetry is the design: only decode receives the `x-prefiller-host-port` header, because
only decode needs to go and fetch a prefill.

### What `nonCachedTokens` actually does

Four identical requests, `nonCachedTokens: 1`, with the decider's own debug output:

| Request | `absolute hit prefix len` | `prompt length` | Suffix | Decision |
|---|---|---|---|---|
| 1 | 0 | 109 | 109 | **split** — prefill served it |
| 2-4 | 128 | 109 | **-19** | `using decode profile only` |

From `prefix_based_pd_decider.go`:

```go
hitPrefixTokens = info.CachedBlockCount() * info.BlockSizeTokens()
nonCachedTokens = inputTokens - hitPrefixTokens
return nonCachedTokens >= d.config.NonCachedTokens
```

`1` therefore means *"split when at least one token of this prompt is not already cached on
the pod that would decode it"* — not "always split", which is what this document said before
the measurement. `0` disables the plugin outright, which is what silently disabled P/D on the
first cluster.

**The economics it encodes.** Remote prefill buys parallelism and pays for it with a KV
transfer. When the decode pod already holds the prompt there is no prefill work left to move,
so the transfer would be pure cost. Splitting once on a cold prompt and never again for that
prompt is the optimal behaviour, not a bug — which is why an experiment that sends the *same*
prompt repeatedly makes a working P/D setup look broken.

### Two measurement artifacts worth knowing

**The suffix went negative.** 109 tokens occupy two 64-token blocks, so the router credits
128 tokens of cache against a 109-token prompt. Block-granular accounting rounds up on the
router side.

**Two components disagree about both numbers.** The EPP reports a 109-token prompt and 128
cached tokens; the simulator reports 102 queried tokens and 64 hits. Same render service, but
the EPP tokenizes through the chat template while the simulator tokenizes what it assembles,
and the router counts *stored* blocks where the server counts *matched* ones. Neither is
wrong; they answer different questions. A dashboard that plots them as if they were the same
quantity would be.
