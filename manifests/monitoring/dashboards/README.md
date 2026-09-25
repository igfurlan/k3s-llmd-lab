# dashboards

The JSON here is the source of truth. Grafana in this lab has **no persistence** —
its database is an `emptyDir`, so a pod restart wipes anything created in the UI.
That is deliberate rather than neglectful: dashboards live in git and are
provisioned from ConfigMaps, so "restart Grafana" costs nothing and the UI is
never the only copy.

## Provisioning

Grafana's sidecar watches for ConfigMaps labelled `grafana_dashboard=1` in any
namespace and loads what they contain. So a dashboard ships as a ConfigMap
generated from the file:

```bash
kubectl -n monitoring create configmap llm-d-routing-dashboard \
  --from-file=llm-d-routing.json=$HOME/manifests/monitoring/dashboards/llm-d-routing.json \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n monitoring label configmap llm-d-routing-dashboard grafana_dashboard=1 --overwrite
```

Re-run both after editing the JSON; the sidecar picks up the change within about
a minute, with no Grafana restart.

## Editing

Edit in the Grafana UI while iterating, then **export back into this file** —
dashboard settings → JSON Model, or the share/export dialog — and commit. A
dashboard that exists only in a browser session is one pod restart from gone.

One gotcha inherited from [igfurlan/claude-dashboard](https://github.com/igfurlan/claude-dashboard):
if you import a dashboard downloaded from grafana.com, strip its `__inputs` and
`__requires` keys first. They belong to Grafana's interactive import wizard, and
left in place the sidecar either refuses the file or provisions a dashboard whose
datasource never resolves.

## llm-d-routing.json

| Row | Panels | What it answers |
|---|---|---|
| Headline | routed requests, prefix cache hit ratio, P/D decisions, ready endpoints | Is traffic flowing, and is caching working? |
| Routing | split decisions by outcome, scheduling cost p50/p95 | What is the picker deciding, and what does deciding cost? |
| Cache | hit ratio by role, KV utilisation by role | Where are the cached prefixes, and which pod is filling up? |
| Throughput | prompt vs generation tokens by role, queue depth by role | Is prefill work landing on prefill and decode work on decode? |
| Latency | TTFT p95, per-plugin p95 | What does a caller feel, and which plugin is expensive? |
| Real vs simulated | CPU and memory per pod | ollama has no metrics endpoint; cAdvisor shows a real model burning CPU beside simulators that do not |

Every `vllm:*` query works unchanged against real vLLM — the simulator emits
vLLM's metric names, which is what makes a GPU-free lab worth building.

The `llm_d_ai_role` label comes from the PodMonitor's `podTargetLabels`, which
copies the pod's `llm-d.ai/role` label onto each series (Prometheus replaces the
dots and slashes with underscores). Without it, prefill and decode would be two
anonymous pods and none of the by-role panels would be possible.

## llm-d-gateway.json

Provisioned the same way, with its own ConfigMap:

```bash
kubectl -n monitoring create configmap llm-d-gateway-dashboard \
  --from-file=llm-d-gateway.json=$HOME/manifests/monitoring/dashboards/llm-d-gateway.json \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n monitoring label configmap llm-d-gateway-dashboard grafana_dashboard=1 --overwrite
```

| Row | Panels | What it answers |
|---|---|---|
| Decomposition | seconds per phase per request, ext_proc share of the request | Where does a request's time actually go? |
| Cross-check | gateway's ext_proc p95 against the picker's own p95, request latency per arm | Do two independent observers of the same decision agree, and which arm is faster? |
| Load | request rate per arm, shed counters | Is the right arm being driven, and is the front door refusing anything? |

### Why this exists separately from llm-d-routing.json

That dashboard answers *what the picker decided*. This one answers *what the
request cost, and where*. They draw on different components — one reads the model
servers and the endpoint picker, this one reads the gateway.

The gateway is the only component that sees a whole request, and it labels its
outbound calls by kind:

```
agentgateway_upstream_call_duration_seconds_count{kind="Policy",subtype="ExtProc"}  12104
agentgateway_upstream_call_duration_seconds_count{kind="Primary",subtype="Http"}    12344
```

So the ext_proc round trip to the endpoint picker is its own series, separate
from the call to the model server. **That makes the scheduling cost measurable
from outside the scheduler** — the panel "two observers, one decision" plots the
gateway's measurement against the picker's own, and a gap between them is network
and gRPC overhead that neither component can see alone.

The arithmetic in those two counters is also a free consistency check: 12,344 =
12,104 + 240. Every InferencePool request made an ext_proc call, and the 240
extra primary calls are exactly the round-robin control arm, which has no picker.

### Two method notes, because both are easy to get wrong

**Percentiles do not add.** A stacked chart of p95s is meaningless — the p95 of
the parts is not the p95 of the whole. The decomposition panel therefore uses
mean seconds per request (`rate(_sum) / rate(requests_total)`), where both series
share one denominator and genuinely sum. Percentiles appear only on panels that
describe what a caller feels, never on a stack.

**`route` is what separates the arms.** `route="llm-d/sim-pool"` is the
InferencePool path and `route="llm-d/sim-roundrobin"` is the control. Both arms
can now sit on one panel over one time window, rather than being compared across
two separate windows — which is how an earlier benchmark run managed to measure
nothing at all.

### What is not here

agentgateway v1.5.0 on this cluster emits **no `gen_ai` metrics** — no
time-to-first-token, no token counts. Those appear in upstream documentation but
not in this build, so TTFT is still only measured at the router and there is no
second opinion on it. If a later version adds them, this is the dashboard they
belong on.
