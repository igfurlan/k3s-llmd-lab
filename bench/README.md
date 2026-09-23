# A/B: does prefix-aware routing actually beat round-robin?

The dashboard shows a prefix cache hit ratio around 33%. Nothing on it
establishes that **llm-d caused that**. This is the experiment that does.

## The claim under test

> Routing that understands the payload — which pod holds this prompt's prefix,
> how deep each queue is — serves the same traffic better than round-robin.

Plausible, widely asserted, and worth measuring on your own cluster before
repeating.

## Design

| Arm | Path | Routing |
|---|---|---|
| **A** | `/v1/chat/completions` | Gateway → EPP → InferencePool. Prefix-aware, with prefill/decode disaggregation |
| **B** | `/rr/v1/chat/completions` | Gateway → plain `Service` → kube-proxy round-robin |

**The same two model servers serve both arms.** Separate replicas would compare
two sets of caches on two sets of hardware, and any result could be waved away as
placement luck. Same pods, caches cleared between runs, one variable.

The workload is the other half of the design: a ~250-token system prompt shared
by every request, a ~40-token per-user persona, and a short varying question. Six
users, ten turns each. That is the shape of real LLM traffic — and the shape
where cache locality is worth something. Unique random prompts would show
nothing (nothing to cache); one identical prompt would show everything and prove
nothing.

## Protocol

Run from `k3s-server`, with `KUBECONFIG` exported. **Clear the caches before each
arm** — a warm cache from the previous run is the easiest way to get a flattering
number for whichever arm went second.

```bash
chmod +x ~/bench/ab-bench.sh

# --- Arm A: prefix-aware ---
kubectl -n llm-d rollout restart deploy/sim-prefill deploy/sim-decode
kubectl -n llm-d rollout status deploy/sim-prefill; kubectl -n llm-d rollout status deploy/sim-decode
sleep 15
~/bench/ab-bench.sh /v1/chat/completions 60 4 6

# --- Arm B: round robin ---
kubectl -n llm-d rollout restart deploy/sim-prefill deploy/sim-decode
kubectl -n llm-d rollout status deploy/sim-prefill; kubectl -n llm-d rollout status deploy/sim-decode
sleep 15
~/bench/ab-bench.sh /rr/v1/chat/completions 60 4 6
```

The script prints the Grafana window for each run. Compare the two windows on
the **llm-d — Inference Routing** dashboard.

## What to compare, and what each answer means

| Measure | Where | If arm A wins | If it does not |
|---|---|---|---|
| **Prefix cache hit ratio** | dashboard, or the query below | Prefix-aware routing is keeping each user's turns on one pod | Either the workload has too little shared prefix to matter, or the scorer weights are wrong |
| **Client latency p50/p90** | the script's own output | Cache hits are translating into time saved | Caching is working but prefill was never the bottleneck here |
| **TTFT p95** | dashboard | Same, measured at the router rather than the client | |
| **Split decisions** | dashboard | Arm B has none by construction — it has no EPP at all | |

Exact hit ratio per arm, as a number rather than a glance:

```bash
curl -sG 'http://localhost:9090/api/v1/query' --data-urlencode \
  'query=sum(increase(vllm:prefix_cache_hits_total[10m])) / sum(increase(vllm:prefix_cache_queries_total[10m]))'
```

Run it right after each arm, with the window covering only that arm.

## Expected, and why a null result is still a result

With six users and a ~290-token shared prefix, arm A should hold a materially
higher hit ratio: round-robin scatters each user's turns across both pods, so
roughly half of them land somewhere cold.

Latency is the less certain half. These are **simulated** model servers, and the
simulator models prefill time rather than performing it — so a cache hit saves
simulated work. If the simulator's prefill cost is configured low, arm A can win
decisively on cache hits and tie on latency.

**That is a finding, not a failure**, and it is the honest one: this lab can
demonstrate that prefix-aware routing *changes where requests go and how often
caches hit*, which is a claim about the scheduler. Proving what those hits are
worth in seconds needs real weights on real accelerators. Saying so is more
useful than a latency graph that quietly measures a configured constant.

## Results

Record each run here — date, arm, hit ratio, latency percentiles, and anything
surprising. A benchmark whose numbers live only in a terminal is a benchmark
nobody can check.
