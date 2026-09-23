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

### 2026-09-23 — 240 requests, concurrency 4, 6 users

| | Arm A (prefix-aware + P/D) | Arm B (round-robin) |
|---|---|---|
| Prompt tokens queried | **124,552** | 62,276 |
| Cache hits | 93,056 | 46,208 |
| **Hit ratio** | **74.7%** | **74.2%** |
| Distribution across the two pods | 62,276 / 62,276 | 34,749 / 27,527 |
| Latency p50 | 12.2 ms | **5.3 ms** |
| Latency p90 | 14.4 ms | 6.2 ms |
| Failures | 0 / 240 | 0 / 240 |

**Prefix-aware routing produced no cache advantage: 0.5 points, which is noise.
It cost 2.3× the client latency.**

### Why — the hit ratio is arithmetic, not routing

Each request carries a ~259-token prompt. At `block-size 64` the shared system
prompt occupies exactly **three full blocks = 192 tokens**, and

```
192 / 259 = 74.1%
```

which is both arms' measured hit ratio to within rounding. So the entire hit
ratio comes from the system prompt every request shares, and **nothing else hit
at all**. The per-user persona is ~40 tokens — under one block — so it can never
be cached, no matter where it is routed.

Routing had nothing to route for:

1. **The shared prefix is shared by everyone.** Both pods cache it within the
   first couple of requests, so scattering a user's turns costs nothing.
2. **Nothing ever evicts.** `kv-cache-size 1024` blocks is 65,536 tokens; the
   entire working set of this benchmark fits on every pod simultaneously.
3. **The distinguishing prefix is sub-block.** Below 64 tokens, per-user context
   is invisible to a block-granular cache.

### The conclusion worth keeping

> Cache-aware routing pays when the **distinguishing** prefix is long enough to
> form whole blocks *and* the aggregate working set exceeds what one pod can
> hold. When neither holds, round-robin matches it exactly — and wins on
> latency, because it does not pay for a scheduling round trip.

This is the opposite of the usual benchmark, which is designed until the new
thing wins. The mechanism is real; the conditions it needs are specific, and a
lab with two pods, one shared prompt and an oversized cache is not one of them.

### The cost side

Arm A queried **exactly twice** as many prompt tokens, split perfectly evenly —
that is P/D disaggregation: prefill processes the prompt, and decode looks it up
as well. On real hardware decode's side is served by the KV cache transferred
from prefill rather than recomputed, so this doubling reflects how the simulator
accounts for a lookup more than genuinely duplicated work. It is a caveat, not a
conclusion, and separating the two would need a real engine.

The latency gap is easier to attribute: arm A pays an ext_proc round trip to the
scheduler and, on a split, a second backend call. Against a simulator that
returns in microseconds there is nothing to win back. **On a GPU, prefilling 259
tokens costs tens of milliseconds and skipping it dwarfs a 95 µs scheduling
decision** — so the sign of this result would likely flip. The hit-ratio finding
transfers between environments; the latency number is a property of this lab and
should not be quoted without it.

### What would make the mechanism show

Three changes, each testable here, in the order most likely to matter:

1. **Give each user a prefix worth caching** — 300+ distinct tokens per persona,
   so a user's context spans several blocks of its own.
2. **Shrink the cache below the working set** — drop `--kv-cache-size` until
   eviction starts. Locality only matters when memory is scarce; this benchmark
   removed scarcity by accident.
3. **Add model server replicas** — with more pods, round-robin scatters further
   while the picker should still concentrate.

Until then the honest claim from this lab is narrow and defensible: the
scheduler demonstrably controls *where* requests go, and the plumbing measured
here works. What that control is worth depends on conditions this hardware
cannot create.
