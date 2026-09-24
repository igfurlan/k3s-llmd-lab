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

## Why the latency numbers below measure nothing

Latency was always the less certain half of this experiment. It turned out to be
worse than uncertain — it was empty, and this was found only after the results
were published.

These are **simulated** model servers, and the simulator's latency parameters all
default to **zero**: `prefill-overhead`, `prefill-time-per-token`,
`inter-token-latency`, `kv-cache-transfer-time-per-token`. Nothing in
`manifests/` sets any of them, and `latency-calculator` is unset too.

So prefill costs nothing. The simulator's own per-token formula is

```
prefill_time = prefill-overhead + (n − n_cached) × prefill-time-per-token
```

and `n_cached` — the cache hit, the entire point of the experiment — multiplies a
per-token cost of zero. **A cache hit could not have saved time here, whatever
the routing did.** Arm A's 2.5× latency is its own scheduling overhead measured
against a backend that is free: the worst possible case for it, and not a
property of real serving.

**The hit-ratio result stands.** It is a claim about the scheduler — where
requests go and how often caches hit — and it never depended on latency. The
latency columns need replacing rather than amending, which is what adopting one
of the simulator's shipped latency profiles does. See
[next-increments.md](../docs/next-increments.md).

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
| Latency p50 † | 13.4 ms | **5.4 ms** |
| Latency p90 † | 16.2 ms | 6.8 ms |

† **These two rows measure scheduling overhead against zero-cost backends, not
serving latency.** Kept for the record, not for the conclusion — see above.

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

> **Superseded by run 3.** Everything in this subsection reasons about latency
> measured against backends that cost nothing, and its central prediction — that
> the 2.5× would shrink or flip once prefill cost real time — was tested and
> held. Kept as written because the prediction was right and the record of it is
> worth more than a tidy edit.


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

---

## Run 3 — under a real latency model, 2026-09-24

Identical workload, replicas and cache size to run 2. The only change is that
both simulators now carry upstream's `small-l40s-edge-per-token` latency profile
(`prefill-overhead: 20ms`, `prefill-time-per-token: 350us`,
`inter-token-latency: 15ms`, `kv-cache-transfer-time-per-token: 12us`,
`time-factor-under-load: 1.5`, `max-num-seqs: 4`) instead of the zero everything
defaulted to. Routing was **not** changed: this is still the estimating
`prefix-cache-scorer`.

| | Arm A (prefix-aware + P/D) | Arm B (round-robin) | Δ |
|---|---|---|---|
| **Hit ratio** | **84.8%** | 78.4% | **+6.4 pts** |
| Prompt tokens queried | 177,832 | 88,916 | 2× |
| Cache hits | 150,848 | 69,696 | |
| Latency p50 | 426 ms | **373 ms** | +53 ms (1.14×) |
| Latency p90 | 854 ms | **801 ms** | +53 ms (1.07×) |
| Latency p99 | 927 ms | **891 ms** | +36 ms (1.04×) |
| mean | 471 ms | 433 ms | +38 ms |

Against the 86.4% ceiling: arm A captures **98%** of what is achievable, arm B
**91%**.

### The control arm reproduced exactly

Arm B returned 88,916 tokens queried and 69,696 hits — **bit-identical to run
2**, across a change that altered every timing in the system. Round-robin over a
fixed pod set with a deterministic request sequence lands the same requests on
the same pods in the same order, so its cache behaviour is reproducible. That is
a stronger validation of this harness than anything run 2 produced.

### Run 2's headline was an artifact, and this corrects it

Run 2 reported that prefix-aware routing *"cost 2.5× the latency"*. It did not.
That ratio was a fixed scheduling overhead divided by a 5 ms request against
backends that cost nothing. Amortised against a real ~400 ms request the same
overhead is **1.14×** — and it buys 6.4 points of hit ratio.

**The sign did not flip, but the magnitude collapsed**, which is what the run 2
write-up predicted would happen on real hardware. It happened here instead,
without a GPU, by giving the simulator the latency model it always had a slot
for.

### The experiment compares two architectures, not one variable

Arm A queried 177,832 tokens against arm B's 88,916 — exactly double, because
**arm A splits every request** (prefill pod, KV transfer, decode pod) while arm B
touches one pod. So the comparison is *prefix-aware routing **and** prefill/decode
disaggregation* against *round-robin with neither*.

Run 2 had the same confound. Nothing cost time, so it never surfaced.

Arm A's +53 ms is therefore an unseparated mix of the KV transfer (~4.4 ms now
that it costs anything), the extra hop through the routing sidecar and the remote
prefill call, queueing on a hot prefill pod (below), minus roughly 8 ms of
genuine caching benefit. **This write-up does not attribute a breakdown, because
the data does not support one.**

The experiment that would: raise `nonCachedTokens` until requests stop splitting.
Arm A then becomes prefix-aware routing *without* P/D, and the difference against
today's arm A is disaggregation's real cost.

### What the latency model exposed: the pool is hot-spotted

Per-pod, arm A:

```
10.42.1.45   queried 88916 tokens   hit 75648   (85.1%)   <- all of it
10.42.1.46   queried     0
10.42.1.47   queried     0
```

**One prefill pod served every request. Two served nothing.** Decode spread over
two of three; the third was idle.

The cause is the prefill profile's own weights:

```yaml
- pluginRef: prefix-cache-scorer
  weight: 3
- pluginRef: queue-scorer
  weight: 1
```

Once one pod holds the shared system prompt it wins every scoring round, and one
unit of queue pressure cannot outvote three units of cache affinity. The
queueing shows in the percentiles: arm A's p90 is almost exactly 2× its p50.

**And this is new.** Run 2 recorded its own prefill distribution —
*"15,006 to 44,458 tokens across the three prefill pods"* — so all three were
working, unevenly. Run 3 puts 100% on one. The scorer weights are identical
between the runs, so the weights alone do not explain it.

What changed is that requests now take time, and that closes a feedback loop
that was previously open. At zero cost each request finished before the next
arrived: no queue ever formed, no pod stayed warm enough to dominate, and which
pod won varied. At ~400 ms and concurrency 4 the requests overlap, so the first
pod to hold the shared prefix keeps winning, keeps being warm, and keeps
winning — while `queue-scorer` at weight 1 cannot outvote `prefix-cache-scorer`
at weight 3 no matter how deep its queue gets.

So the latency model did not merely make an existing cost visible. **It created
the hot spot**, by making cache affinity self-reinforcing in a way that
instantaneous requests never allowed.

It also explains the hit ratio rising 82.6% → 84.8% with no routing change:
concentration maximises cache warmth, because one pod holding everything never
misses on a prefix a sibling happens to hold. **Concentration helps the hit
ratio and hurts the tail.** That trade-off was structurally unobservable in this
lab until this run, and it is the most useful thing run 3 produced.

It is also the concrete argument for increment A4. Upstream's
`prefix-cache-affinity-filter` exists precisely to break this loop: it falls
back to the least-loaded pods once the cache-warm set saturates past
`peakPrefillThroughput`. The lab now has an observed reason to want that
mechanism rather than a documentation-derived one.

### Two caveats on this run

- **`--max-num-seqs` changed from the default 5 to 4** in the same step, as part
  of adopting the profile whole. It caps concurrent sequences per pod, so it
  affects queue depth and therefore what `queue-scorer` sees. Some of the
  2.2-point hit-ratio move may be queueing rather than latency.
- **Decode dominates.** At `max_tokens: 48` and 15 ms per token, decode is ~90%
  of a request; prefix caching can only ever attack the ~40 ms of prefill. A
  sharper version of this experiment would use longer prompts or shorter outputs.

---

## Weight sweep — the ratio was the wrong hypothesis, 2026-09-24

Run 3 left prefill hot-spotted on one of three pods, and the obvious suspect was
the prefill profile's `prefix-cache-scorer : queue-scorer` ratio of 3:1. Four
points, everything else held fixed, EPP and simulator caches cleared between
each:

| prefix:queue | ratio | Hit ratio | p50 | p90 | p99 | prefill pods used | decode pods used |
|---|---|---|---|---|---|---|---|
| **3:1** | 3.000 | 84.83% | 426 ms | 854 ms | 927 ms | **1 of 3** | 2 of 3 |
| **3:3** | 1.000 | 84.75% | 354 ms | 866 ms | 965 ms | 2 of 3 | 2 of 3 |
| **3:8** | 0.375 | 85.29% | 370 ms | 853 ms | 938 ms | 2 of 3 | 2 of 3 |
| **1:8** | 0.125 | 85.04% | 310 ms | 802 ms | 859 ms | **1 of 3** | 3 of 3 |

**The hit ratio moved 0.54 points across a 24× change in the ratio**, and the
load spread went 1 → 2 → 2 → 1. Non-monotonic, so it is not tracking the
weights.

### Why: queue-scorer returns a constant

From the EPP's own scoring debug, the three prefill candidates:

```
prefix-cache-scorer   qmjw8   score 0.5
queue-scorer          qmjw8   score 1
queue-scorer          mrg2g   score 1
queue-scorer          qvsl8   score 1
```

with pod state:

```
mrg2g   RunningRequestsSize 0   WaitingQueueSize 0
qvsl8   RunningRequestsSize 0   WaitingQueueSize 0
qmjw8   RunningRequestsSize 1   WaitingQueueSize 0
```

`queue-scorer` scored **1 for every pod**, including the one with a request in
flight. It scores on `WaitingQueueSize`, and that is 0 everywhere.

So the weighted sum is `prefix_w x prefix_score + queue_w x 1`, and the queue
term is **the same constant on every candidate** — it cancels in the argmax.
`prefix-cache-scorer` was the only plugin deciding anything, at every ratio
tested. The arithmetic checks against the logged final scores: `qmjw8` 2.5 and
the others 1, which is `3(0.5) + 1(1)` and `3(0) + 1(1)`.

**No queue ever forms because the pool is never loaded.** Concurrency 4, three
prefill pods, `max-num-seqs 4` — capacity 12 concurrent sequences against 4
offered. For `queue-scorer` to carry signal, offered concurrency has to exceed
`replicas x max-num-seqs`.

### What the 1-vs-2 pod variation actually was

A startup race. Every cache begins cold, so every prefix score is 0, the first
request breaks a three-way tie arbitrarily, and whichever pod warms first keeps
winning. Sometimes two warm before the loop closes. With n=1 per point and this
race dominating, **none of the latency differences above are distinguishable
from noise** and they should not be read as a trend.

### This retracts run 3's stated mechanism

Run 3 concluded the hot spot was `queue-scorer` at weight 1 being unable to
outvote `prefix-cache-scorer` at weight 3. That is wrong: it is not losing the
vote, it is not voting. Raising it to 8 changes nothing, because 8 x constant
is still constant.

What survives from run 3: the latency model created the hot spot, and run 2's
per-pod spread across all three prefill pods is evidence it was not there
before. What does not survive is the explanation of *how*.

### The sweep to actually run

Repeat these four points at concurrency above 12, where `queue-scorer` has a
queue to score:

```bash
~/bench/weight-sweep.sh 3 1 480 24 6
~/bench/weight-sweep.sh 3 3 480 24 6
~/bench/weight-sweep.sh 3 8 480 24 6
```

If the hit ratio stays flat there too, the ratio genuinely does not matter for
this workload and the hot spot needs `prefix-cache-affinity-filter` — a filter
with a real load gate — rather than a reweighting. That is increment A4.

### The same sweep at concurrency 24

The sweep above measured nothing because the pool was never loaded. Repeated at
concurrency 24 against a pool with capacity 12 (3 prefill pods x
`max-num-seqs 4`), 480 requests per point:

| prefix:queue | Hit ratio | p50 | p90 | p99 | mean | prefill pods | decode pods |
|---|---|---|---|---|---|---|---|
| **3:1** | 83.79% | 964 ms | 1600 ms | 2283 ms | 1028 ms | **1 of 3** | 3 of 3 |
| **3:3** | 83.95% | 888 ms | 1506 ms | 2008 ms | 953 ms | **2 of 3** | 3 of 3 |
| **3:8** | 83.86% | 848 ms | 1515 ms | 2271 ms | 931 ms | **2 of 3** | 3 of 3 |

**Hit ratio range: 0.16 points** — flatter than the 0.54 at concurrency 4. The
ratio does not affect cache locality for this workload, at either load level.

**Latency does respond, monotonically**: p50 964 -> 888 -> 848 and mean
1028 -> 953 -> 931. A **12% p50 improvement at no measurable cost in hit ratio.**

So the earlier conclusion needs narrowing rather than keeping: `queue-scorer`
returns a constant **below saturation**, which is the condition it was measured
in. Load the pool past capacity and it carries signal. Both statements are about
the same plugin; only the second is general.

The practical version, for this workload: **raise `queue-scorer`'s weight.** It
buys tail latency and costs nothing.

### Prefill never uses all three pods. Decode always does.

Across all six sweep points at both concurrency levels, prefill used one or two
of its three pods and **never all three**. Decode used all three in every run at
concurrency 24.

Same cluster, same requests, same replica count. The two profiles differ by
exactly one plugin:

```yaml
- name: prefill                     - name: decode
  - prefill-filter                    - decode-filter
  - prefix-cache-scorer   weight 3    - prefix-cache-scorer         weight 3
  - queue-scorer          weight 1    - queue-scorer                weight 2
                                      - kv-cache-utilization-scorer weight 2
```

`kv-cache-utilization-scorer` reads `KVCacheUsagePercent`, and the EPP's scoring
debug shows that field carrying a real value — `0.3125` on a busy pod against
`0` on idle ones — where `WaitingQueueSize` was 0 on all of them. A signal that
differentiates, next to one that did not.

**The confound:** decode also holds each request roughly ten times longer
(~390 ms of token generation against ~40 ms of prefill), so any load signal has
far more time to register on that side. This may be the scorer or it may be the
dwell time, and this data cannot separate them.

Both readings point the same way — prefill's load signals are too brief to
differentiate pods — and the test is the same either way: add
`kv-cache-utilization-scorer` to the prefill profile and see whether prefill
starts using its third pod.

### queue-scorer's signal, confirmed

`WaitingQueueSize` across the concurrency-24 runs, from the EPP's own scoring
debug:

```
2223  "WaitingQueueSize":0
  83  "WaitingQueueSize":1        368  "WaitingQueueSize":2
 717  "WaitingQueueSize":3        695  "WaitingQueueSize":4
 276  "WaitingQueueSize":5         72  "WaitingQueueSize":6
  12  "WaitingQueueSize":7
```

Queues up to seven deep, with roughly half of all samples non-zero. At
concurrency 4 this field was 0 on every pod, every time. The narrowed claim
holds: **`queue-scorer` is a constant below saturation and an input above it.**

### Adding kv-cache-utilization-scorer to prefill: the hypothesis held, the fix did not

Same 3:8 point, one plugin added to the prefill profile, everything else fixed:

| | without kv-util | with kv-util at weight 2 |
|---|---|---|
| prefill pods used | 0 / 87,194 / 90,698 — **2 of 3** | 59,418 / 27,823 / 90,651 — **3 of 3** |
| **busiest pod's share** | **50.98%** | **50.96%** |
| Hit ratio | 83.86% | 83.92% |
| p50 | 848 ms | 938 ms |
| p90 | 1515 ms | 1618 ms |
| p99 | 2271 ms | 2901 ms |
| mean | 931 ms | 1012 ms |

**The hypothesis was right: prefill was missing a load signal, not misweighted.**
Adding the scorer put all three pods to work for the first time in any run.

**It did not help.** The busiest pod's share is unchanged at 51%. The third pod
took work from the *second* pod, not from the bottleneck, so peak load is
identical and every latency percentile is worse.

#### Why: the two scorers are antagonistic when memory is scarce

The caches here are 16 blocks *deliberately*, sized to force eviction — see the
Design section. So **a pod holding a useful warm cache is by construction a pod
near capacity.** `kv-cache-utilization-scorer` exists to steer away from full
pods, so it penalises precisely the pods `prefix-cache-scorer` is trying to
select. The two plugins pull in opposite directions exactly when caching
matters most.

The per-pod hit ratios show it: 86.7% and 87.4% on the two lightly-loaded pods
against 83.5% on the hot one, while the aggregate stays pinned at 83.9%. Traffic
is being pushed toward cold pods, which then warm and score well individually,
with no aggregate gain.

This is a tuning observation that should generalise beyond this lab: **on any
deployment where KV memory is the binding constraint, cache-utilisation scoring
and prefix-affinity scoring are in tension**, and adding the former to a profile
will spread load without necessarily improving anything.

#### Confidence

The categorical result — 2 pods to 3 — is a step change and is believable at
n=1. **The latency regression is not.** Single-run variance in this harness has
been large: the concurrency-4 sweep produced p50 values from 310 ms to 426 ms
across configurations later shown to be making identical routing decisions. A
10% p50 delta sits inside that. Repeat both points before treating the latency
column as a result.
