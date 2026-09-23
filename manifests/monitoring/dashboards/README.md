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
