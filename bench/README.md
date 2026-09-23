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

**The same six model servers serve both arms** (3 prefill + 3 decode). Separate
replicas would compare two sets of caches on two sets of hardware, and any result
could be waved away as placement luck. Same pods, caches cleared between runs,
one variable.

Replica count is not a detail here. With one pod per role the picker logs
`num-of-candidates: 1` — there is no decision to make, and both arms are the same
thing pointed at the same pod. That is what run 1 measured.

The workload is the other half of the design: a ~250-token system prompt shared
by every request, a ~200-token DISTINCT per-user persona, and a short varying
question. Six users, forty turns each. Both lengths matter: the shared part must
be big enough to cache, and the per-user part must exceed the 64-token block size
or it cannot be cached at all — which is the mistake run 1 made.

And the caches are deliberately too small (`--kv-cache-size 16` blocks, 1024
tokens). Locality only pays when memory is scarce; with a cache that holds
everything, scattering costs nothing and round-robin ties.

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
~/bench/ab-bench.sh /v1/chat/completions 240 4 6

# --- Arm B: round robin ---
kubectl -n llm-d rollout restart deploy/sim-prefill deploy/sim-decode
kubectl -n llm-d rollout status deploy/sim-prefill; kubectl -n llm-d rollout status deploy/sim-decode
sleep 15
~/bench/ab-bench.sh /rr/v1/chat/completions 240 4 6
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

## Why a null result is still a result

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

### Run 2 — tuned, 2026-09-23

Three replicas per role, `kv-cache-size 16` blocks, ~200-token personas,
`prefix-cache-scorer` added to the decode profile. 240 requests, concurrency 4,
6 users.

| | Arm A (prefix-aware + P/D) | Arm B (round-robin) |
|---|---|---|
| **Hit ratio** | **82.6%** | **78.4%** |
| Prompt tokens queried | 177,832 | 88,916 |
| Cache hits | 146,816 | 69,696 |
| Latency p50 | 13.4 ms | **5.4 ms** |
| Latency p90 | 16.2 ms | 6.8 ms |

**+4.2 points, where run 1 showed 0.5.** The mechanism is visible once the
conditions exist for it to matter.

#### Against the ceiling, which is the honest denominator

Prompts average 370 tokens (88,916 ÷ 240 in arm B, one touch per request). At
64-token blocks only 5 full blocks — 320 tokens — can ever be cached; the
trailing 50 tokens are recomputed every time by anyone.

```
ceiling = 320 / 370 = 86.4%
```

| | Hit ratio | Share of the achievable | Prompt tokens recomputed |
|---|---|---|---|
| Arm A | 82.6% | **95.6%** | 17.4% |
| Arm B | 78.4% | 90.7% | 21.6% |

So prefix-aware routing recovered about **a quarter of the recomputation that
round-robin leaves on the table** (21.6% → 17.4% of tokens). A 4-point headline
understates it; against the reachable maximum it is the difference between
capturing 91% and 96% of the available caching.

#### What each arm's distribution shows

Arm A concentrated unevenly on purpose — 15,006 to 44,458 tokens across the
three prefill pods — because it is routing by prefix, and prefixes are not
evenly sized. Arm B spread more evenly (16,304 / 21,160 / 16,992) except for one
decode pod that received almost nothing (2,602), which is small-sample
randomness in kube-proxy rather than a policy.

**Even distribution is not the goal.** Round-robin achieves it by construction
and gets a worse hit ratio for it. That is the whole argument in one line.

#### The cost is unchanged and still real

Arm A remains ~2.5× slower per request, and still touches prompt tokens twice
(177,832 ≈ 2 × 88,916) because P/D sends the prompt to prefill and decode looks
it up as well. Against a simulator that returns in microseconds, a scheduling
round trip and a second backend call buy nothing back. **On a GPU, recomputing
64 extra prompt tokens costs far more than 8 ms of routing** — which is where
this trade is supposed to pay, and is exactly what this hardware cannot show.

### Run 1 — untuned, 2026-09-23

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

### Run 1's conclusion, which run 2 refined

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
