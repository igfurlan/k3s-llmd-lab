# What's next

Three parts: the increment that was asked for, the things the original plan left
unfinished, and a menu of experiments this cluster is already equipped to run.

Everything here is scoped against **what exists on the cluster today**. Where a claim
needs checking before it can be relied on, it is written as a check, not as a fact.

---

# Backlog at a glance

Updated 2026-09-25. **This table is the thing to keep current** — the sections below hold
the reasoning, but this is the list.

### Done

| | What came of it |
|---|---|
| Simulator latency profile (Part 3 §1) | Every latency parameter defaulted to **zero**, so a cache hit could not save time. Adopted upstream's `small-l40s-edge-per-token`. Corrected two published claims |
| Precise prefix-cache routing (Part 1) | Works, on a locally built image. Found **two** upstream defects — [#735](https://github.com/llm-d/llm-d-inference-sim/issues/735) publisher never binds, [#736](https://github.com/llm-d/llm-d-inference-sim/issues/736) KV-event sequence starts at 1. Results in [bench/README.md](../bench/README.md) |
| Scorer weight sweep (Part 3 §4) | The ratio does **not** move the hit ratio, at either load level. Ruled out reweighting by elimination |
| EPP restart survival | approx retains 1 of 5 valid trials, at or below chance. The approximate index dies with its process |
| agentgateway metrics (Part 2) | `manifests/monitoring/52-scrape-gateway.yaml`. Port `metrics`/15020, unauthenticated, verified 41 KB body |

### Open

| Priority | Item | Where | Size |
|---|---|---|---|
| **1** | **Gateway dashboard panels** — decompose latency into gateway / EPP / backend. Needs the real metric names confirmed first | below | S |
| **2** | **Kill the EPP under load** — `failureMode: FailOpen` documented, never exercised | Part 3 §3 | S |
| **3** | **Cache-size sweep** — find where prefix-aware routing stops beating round-robin | Part 3 §2 | S |
| **3.5** | **Flux for GitOps** — the cluster reconciles from git instead of `vagrant upload` + `kubectl apply`. Flux rather than Argo *on purpose*: musashi runs Argo CD, so this gives both tools across the two labs | below | M |
| **4** | **Upstream topology (A4)** — `prefix-cache-affinity-filter` + `token-load-scorer`, `peakPrefillThroughput: 2857` | Part 1 A4 | M |
| **5** | **Inference SLO alerting** — this lab has a dashboard and zero alert rules; musashi has nine | Part 3 §5 | M |
| **6** | **Real vLLM beside the simulators** — one real pod in the pool, proving the EPP cannot tell them apart | Part 2 | M |
| **7** | **Phase 8, a real case** — nothing yet sends real client traffic through the gateway | Part 2 | M |
| **8** | **Multi-turn conversations** — the benchmark sends persona + one question; real chats grow the prompt | Part 3 §6 | S |
| **9** | **Session-based routing** — how much of the benefit comes from a cookie hash? | Part 3 §7 | M |
| **10** | **Predicted-latency routing** — viable now the backends cost real time | Part 3 §8 | M |
| — | **Grafana loses its admin password** on restart. Accept and document, or give it a PVC | Part 2 | XS |

### Watching, not doing

- **[#735](https://github.com/llm-d/llm-d-inference-sim/issues/735) and [#736](https://github.com/llm-d/llm-d-inference-sim/issues/736)** — a release closing both replaces the locally built simulator image.
- **[agentgateway#3420](https://github.com/agentgateway/agentgateway/issues/3420)** — the chart's own PodMonitor omits `podTargetLabels`. Ours does not; if they fix theirs, ours can go.

### Standing rules earned the hard way

- **Three runs minimum** before quoting any latency or pod-distribution number. Only the
  hit ratio survived single-run scrutiny — identical configs produced 848 ms and 932 ms,
  and 2 pods then 3.
- **`helm upgrade` does not restart the EPP.** Plugin config is a ConfigMap, read once at
  startup. Always `rollout restart` explicitly.
- **Check the body, not the status code.** A 200 with zero bytes reads exactly like a
  component that exports nothing.
- **A benchmark that cannot detect its own broken preconditions** will report the chance
  baseline and look reasonable doing it.

---

# Part 1 — Precise prefix-cache routing

> **DONE**, 2026-09-24, on a locally built image (`pr668-seq0`) carrying both upstream
> fixes. Two defects were found on the way and are filed upstream. Results and the full
> narrative are in [bench/README.md](../bench/README.md) and
> [precise-routing-explained.md](precise-routing-explained.md). The sections below are
> kept as the record of how it was planned and what it cost. **A4 is still open** — see
> the backlog table.

## What actually changes

The lab routes on **estimated** cache state. The `prefix-cache-scorer`, with no
`prefixMatchInfoProducerName`, silently falls back to an auto-spawned *approximate*
producer: it maintains its own index of which prefixes it has **sent** where, inferred
from its own past routing decisions.

The precise producer subscribes to the model servers' `BlockStored` / `BlockRemoved`
ZMQ events and indexes what each pod **actually holds**.

Two failure modes separate them, and both are reachable in this lab:

| | Estimated | Precise |
|---|---|---|
| A block the server evicted | still believed resident | `BlockRemoved` removes it |
| Index after an EPP restart | empty — must relearn from live traffic | rebuilt from the replay socket, **only while each pod's replay history still reaches back to its first batch** (see below) |
| A block the router never routed | invisible | seen, if the server published it |

**The replay window is bounded.** A (re)connecting subscriber in llm-d-router v0.10.0 asks
each pod for a replay starting at sequence 0 and accepts it only if the first batch returned
is 0. The simulator keeps the last `kv-events-replay-queue-size` batches (default 1024; vLLM
keeps 10,000). Once a pod has published more than that, a restarted EPP logs
`incomplete replay: expected sequence 0, got N` and ingests nothing from that pod until the
pod restarts. This is router-side, affects vLLM the same way, and is what the open
[llm-d-router#2946](https://github.com/llm-d/llm-d-router/pull/2946) (snapshot recovery)
addresses. `bench/restart-test.sh` restarts the simulators before every trial, so its pods
are always inside the window.

The second row is the demo. The third is why the numbers disagree: the router credits
whole blocks it *believes* it placed, which is how a 109-token prompt earned
**128 cached tokens** in [epp-scheduling.md](epp-scheduling.md).

## The good news: the model-server half is already done

This was configured during the KV-cache work and never used. From
`manifests/10-sim-prefill.yaml` and `11-sim-decode.yaml`:

```yaml
- "--enable-kvcache"      # publishes BlockStored / BlockRemoved
- "true"
- "--block-size"          # must equal tokenProcessorConfig.blockSizeTokens
- "64"
- "--render-url"          # real token IDs, so both sides hash the same spans
- "http://render:8082"
- "--zmq-endpoint"        # podDiscoveryConfig.socketPort
- "tcp://*:5556"
- "--kv-events-replay-endpoint"   # podDiscoveryConfig.replaySocketPort
- "tcp://*:5559"
```

Ports `5556` and `5559` are named and exposed on both Deployments. The `render`
service is up, and its manifest already names the EPP's `token-producer` as a future
consumer. **Nothing on the model-server side needs to change.** The entire increment is
router-side configuration.

## A0 — Three checks before changing anything

**1. Which config key does this chart version take?**

The upstream guide (`llm-d` main) writes `dataLayer.sources`. The v0.10.0 plugin README
writes `data.sources`. One of them is wrong for the chart running here, and a wrong key
is silently ignored — the producer loads, subscribes to nothing, and the scorer falls
back to approximate without complaining.

```bash
kubectl -n llm-d logs deploy/sim-pool-epp | grep -i "config after phase\|source\|extractor"
```

Confirm the parsed config names the producer as an extractor on the notification source.
If neither key parses, read the chart's own schema:

```bash
helm show values oci://ghcr.io/llm-d/charts/llm-d-router-gateway --version v0.10.0 | grep -n -A5 dataLayer
```

**2. Are the simulators publishing at all?**

`--enable-kvcache` has been on since the KV-cache work, but nothing had ever subscribed
when this was written. **Since verified, and the answer was no:** on v0.11.2 the publisher
never binds 5556, and on `main` the events arrive but are dropped because the batches are
numbered from 1. Precise routing needs the simulator image the manifests now pin,
`pr668-seq0` (see `docs/epp-scheduling.md`). What a healthy pod logs:
`"ZMQ publisher bound" endpoint="tcp://*:5556"`.

```bash
POD=$(kubectl -n llm-d get pod -l llm-d.ai/role=prefill -o name | head -1)
kubectl -n llm-d logs $POD -c sim | grep -i "zmq\|publish\|BlockStored"
```

**3. EPP replicas must stay at 1.**

The `token-load-scorer`'s in-flight accounting is per-process, so two replicas each see
half the load and mis-gate the affinity filter. The chart also auto-adds
`--ha-enable-leader-election` above 1 replica, which collapses to active-passive.
This lab runs 1 already — just don't raise it.

## A1 — The minimal swap: one variable changed

Do **not** adopt the upstream guide's plugin set yet. Its profile is a single `default`
with no prefill/decode split, so taking it wholesale would change the scorer source, the
filter topology, the scoring function and the P/D structure in one move — and any result
would be unattributable.

Instead, keep `epp-pd-values.yaml` exactly as it is and make one change: add the
producers, and tell the **existing** scorer where to get its match info.

`manifests/epp-precise-values.yaml` — a copy of `epp-pd-values.yaml` with:

```yaml
        plugins:
        # --- new: the tokenizer the producer needs ---
        - type: token-producer
          parameters:
            # Must match 05-render.yaml and both simulators' --model, or the
            # render call is rejected rather than quietly using the wrong vocab.
            modelName: Qwen/Qwen2.5-1.5B-Instruct
            vllm:
              url: "http://render:8082"

        # --- new: endpoint lifecycle events, so the producer can attach a
        #          ZMQ subscriber per pod as pods come and go ---
        - type: endpoint-notification-source

        # --- new: the precise index itself ---
        - type: precise-prefix-cache-producer
          parameters:
            tokenProcessorConfig:
              # MUST equal the simulators' --block-size 64.
              blockSizeTokens: 64
            # Seeds the index with the routing decision before the server's
            # event arrives. Start FALSE: it is an estimate layered on top of
            # the precise index, and this increment is about removing estimates.
            speculativeIndexing: false
            indexerConfig:
              kvBlockIndexConfig:
                enableMetrics: true
            kvEventsConfig:
              topicFilter: "kv@"
              concurrency: 8
              discoverPods: true
              podDiscoveryConfig:
                socketPort: 5556
                replaySocketPort: 5559

        # ... every existing plugin unchanged, EXCEPT this one: ...
        - type: prefix-cache-scorer
          parameters:
            # THE ENTIRE INCREMENT IS THIS LINE. Without it the scorer falls
            # back to the auto-spawned approximate producer, which is what has
            # been running all along.
            prefixMatchInfoProducerName: precise-prefix-cache-producer

        dataLayer:            # or `data:` — settled by check A0.1
          sources:
          - pluginRef: endpoint-notification-source
            extractors:
            - pluginRef: precise-prefix-cache-producer

        # schedulingProfiles: UNCHANGED. Both profiles, same weights, same
        # filters, same P/D decider.
```

Apply:

```bash
helm upgrade -i sim-pool oci://ghcr.io/llm-d/charts/llm-d-router-gateway \
  --version v0.10.0 --namespace llm-d -f ~/manifests/epp-precise-values.yaml
kubectl -n llm-d rollout status deploy/sim-pool-epp
```

Then confirm from the EPP's own log that the scorer bound to the precise producer, and
that per-pod subscribers came up — one per model-server pod, six in total.

## A2 — Prove it is precise, not just configured

This lab has already been burned once by a feature that was loaded, logged and doing
nothing ([epp-scheduling.md](epp-scheduling.md#configured-is-not-operating)). Apply the
same standard: **find a number that only moves if the work actually happened.**

Two tests, each targeting one thing the estimator provably cannot do.

**Test 1 — the restart.** The estimator's index lives only in EPP memory and is built
from its own routing history. Delete the EPP pod and it wakes up knowing nothing; the
precise producer replays from port 5559 and knows immediately.

```bash
# warm one user's context onto a known pod
~/bench/ab-bench.sh /v1/chat/completions 40 2 1
kubectl -n llm-d logs deploy/sim-pool-epp | grep "num-of-candidates\|prefix" | tail -5

kubectl -n llm-d delete pod -l app.kubernetes.io/name=sim-pool-epp
kubectl -n llm-d rollout status deploy/sim-pool-epp

# same prompt, cold router, warm servers:
#   estimated -> scattered, cached_tokens 0, index relearned from scratch
#   precise   -> same pod, cached_tokens non-zero on the FIRST request after restart
```

Run it against `epp-pd-values.yaml` first, for the control. **A router that survives its
own restart without losing cache locality is the most legible result available here** —
and it is an availability property, not a benchmark number.

**Test 2 — the eviction.** Caches are 16 blocks (1024 tokens) on purpose. Push one pod
past that and the estimator keeps pointing at blocks the server has dropped, while the
precise index received `BlockRemoved`. Watch for requests routed to a pod that then
reports a miss — that gap should close.

## A3 — Run 3 of the A/B, with three arms

`bench/ab-bench.sh` needs no changes. Same protocol as run 2 — restart both Deployments
between arms, 240 requests, concurrency 4, 6 users:

| Arm | Path | Routing |
|---|---|---|
| B | `/rr/v1/chat/completions` | round-robin (the existing control) |
| A | `/v1/chat/completions` | estimated prefix cache (run 2's 82.6%) |
| **C** | `/v1/chat/completions` | **precise prefix cache** |

Run 2's ceiling arithmetic still applies: ~370-token prompts at 64-token blocks cap the
achievable hit ratio at **86.4%**, and estimated routing already reached 82.6% — 96% of
that ceiling. **So the headroom for precise routing on this workload is at most 3.8
points, and that is worth saying out loud before running it.** If arm C lands at 84–86%
the mechanism is confirmed but nearly exhausted; a null result means the workload has no
room left, not that precise routing does nothing.

To give it room, add the condition the estimator specifically handles badly: restart the
EPP mid-run. Arm A loses its index; arm C replays.

## A4 — Optional: the upstream topology

Only after A1–A3 have produced a number. This replaces the scoring structure entirely:
`prefix-cache-affinity-filter` (a **filter** — it eliminates candidates) plus
`token-load-scorer`, dropping `queue-scorer` and `kv-cache-utilization-scorer`.

Two things to work out first.

**It has to compose with P/D.** The guide's profile is a single `default`. Here there
are two profiles behind `disagg-profile-handler`, each already starting with a role
filter. The affinity filter must run *after* `prefill-filter` / `decode-filter` in each
profile, or it will filter across roles.

**`peakPrefillThroughput` has no meaningful value here — but it can be given one.**
The guide's `15926` was calibrated on Qwen3-32B / H100 / TP=2. The filter uses it to
decide when a cache-warm pod is too loaded to stay sticky; set it wrong and either
everything pins to one pod or stickiness never engages.

The simulator makes this tractable. Its per-token prefill model is
`prefill-overhead + (n − n_cached) × prefill-time-per-token`, so peak prefill throughput
is just the reciprocal of the per-token cost:

```
peakPrefillThroughput  =  1 / prefill-time-per-token
```

Adopt the upstream `small-l40s-edge-per-token` profile from Part 3 §1 — which sets
`prefill-time-per-token: 350us` — and the value follows:

```
1 / 350µs  ≈  2857 tokens/s
```

**So `peakPrefillThroughput: 2857`, derived from the profile this cluster is actually
running**, rather than the guide's `15926`, which was calibrated on Qwen3-32B / H100 /
TP=2 and describes a different machine — one about 5.6× faster at prefill than the L40S
this lab is modelling. This depends on Part 3 §1 being done first; until then the
parameter has no defensible value, because prefill costs nothing.

## Risks

- **A wrong config key or a wrong block size fails silently.** Both degrade to
  approximate routing with no error. A2 is not optional.
- **The index is tiny here** — 6 pods × 16 blocks = 96 blocks — so memory is a
  non-issue, but it also means evictions are constant and the index churns. That is the
  point, not a problem.
- **`speculativeIndexing`** re-introduces an estimate on top of the precise index. Leave
  it off for the comparison; turn it on afterwards as its own variable.

---

# Part 2 — Unfinished business from the original plan

## Phase 4: real vLLM — reopened, and now blocked by something else

The plan recorded vLLM as blocked because the guests lacked AVX-512. **That was a
VirtualBox artifact.** Under Hyper-V the host passes the full set through —
`avx512f avx512bw avx512dq avx512vl avx512_bf16 avx512_vnni` — so the stated reason no
longer holds. What blocks it now is 6 GB nodes, which is a different and more negotiable
constraint.

Worth a bounded attempt, in this order:

1. Size the smallest thing that could work. `Qwen2.5-0.5B-Instruct` in bf16 is ~1 GB of
   weights; with a small `--max-model-len` and a small KV cache it may fit a 6 GB node
   alongside k3s. The `render` pod already proves the CPU image runs here.
2. If it does not fit, the host has 32 GB. Raising one agent to 10–12 GB is a
   Vagrantfile change, not an architecture change.
3. **If one real vLLM joins the pool, do not remove the simulators.** A pool with one
   real server and five simulators is a better lab than either: the EPP would score them
   identically because the metric names are identical, which is the lab's central claim
   and has never been directly demonstrated.

## Phase 8: "use it all on a real case" — the thinnest phase

What exists is `bench/ab-bench.sh`: synthetic personas driving a scheduler experiment.
It is a good experiment and a poor application. Nothing yet sends real traffic from a
real client through the gateway.

The smallest honest version: point something a person would actually use at
`/ollama/v1/...` — the gateway already exposes it and `qwen2.5:0.5b` already answers.
Then the interesting question becomes available: **route the same client between the
real backend and the simulated pool, and show the routing layer is backend-agnostic.**

## agentgateway's own metrics are still not scraped

Raised during phase 9 and never done. Prometheus scrapes the simulators (PodMonitor) and
the EPP (authenticated ServiceMonitor). The **gateway** — the component every request
passes through first — exports nothing to it.

This is the missing left-hand edge of every latency panel. Today TTFT is measured at the
router; the gateway's own request duration would separate *time in the gateway* from
*time in the EPP* from *time in the model server*, which is the decomposition the whole
dashboard implies but cannot currently show.

## Grafana reverts its password on restart

Known and documented: no persistence, SQLite on an `emptyDir`, so a pod restart reverts
the admin password to the chart value. Dashboards survive, because they are
ConfigMap-provisioned — which was the deliberate trade. Either accept it and note it in
the README, or give Grafana a PVC. One values change either way.

## Not forgotten, deliberately out of scope

Rook/Ceph and OVN-Kubernetes were split into their own projects on purpose, to keep a
storage layer or a CNI swap from blocking the llm-d work. They stay out.

---

# Part 3 — Worth exploring

Ranked by what this cluster can actually prove, not by what sounds impressive.

## 1. Give the simulator a latency model — CONFIRMED, and the highest-value item here

**This is settled, from source, at the exact version the lab runs.** It was written as a
hypothesis in the first draft of this plan; it is now a finding.

`newConfig()` in `pkg/common/config.go` at **v0.11.2** sets exactly one latency-related
field, `TimeFactorUnderLoad: 1.0`. Every other one — `time-to-first-token`,
`inter-token-latency`, `prefill-overhead`, `prefill-time-per-token`,
`kv-cache-transfer-latency`, `kv-cache-transfer-time-per-token` — is absent and therefore
**zero**. `validate()` only bounds-checks them (`cannot be negative`); it never assigns a
default. The lab's manifests set none of them.

So the model servers cost **zero simulated time**, and the consequences are not
speculative:

- Every millisecond in the A/B is gateway + EPP + sidecar + network. The model servers
  contribute nothing.
- **A cache hit saves nothing because a miss costs nothing.** The simulator's own prefill
  formula is `prefill_time = prefill-overhead + (n − n_cached) × prefill-time-per-token`.
  `n_cached` is in the formula — a cache hit is *meant* to subtract prefill time. At
  `prefill-time-per-token: 0` it subtracts zero. Run 2's latency columns could not have
  shown a caching benefit whatever the routing did.
- P/D's KV transfer is free, so the disaggregation work measured its orchestration and
  none of its economics.
- Arm B's 2.5× latency win is arm A's scheduling overhead against a backend of zero
  cost — the worst possible case for arm A, and not a property of real serving.

There is a second, quieter miss: `latency-calculator` is never set either, which puts the
lab on the path the simulator's docs label **"unset / not recommended"**, kept only for
backward compatibility. The `per-token` calculator is documented for precisely this lab's
purpose — *"use when routing or scheduling experiments require latency to vary with
prompt size."*

**The fix ships with the simulator.** `manifests/latency-profiles/` carries six calibrated
profiles — three hardware targets × `constant` and `per-token` — so the values are adopted
rather than invented.

**Take `small-l40s-edge-per-token`.** It is upstream's *"small (1–3B) model on a single
L40S at the edge"*, which is the closest match to this lab's Qwen2.5-1.5B-Instruct; the
8B/H100 and 70B/8×H100 profiles describe machines this lab is not pretending to be.
`per-token` rather than `constant` because upstream documents it as the one to use when
*"routing or scheduling experiments require latency to vary with prompt size"* — which is
this lab's entire purpose.

```yaml
# manifests/latency-profiles/small-l40s-edge-per-token.yaml, upstream v0.11.2
latency-calculator: per-token
inter-token-latency: 15ms
inter-token-latency-std-dev: 2ms
prefill-overhead: 20ms
prefill-time-per-token: 350us
prefill-time-std-dev: 3ms
kv-cache-transfer-time-per-token: 12us
kv-cache-transfer-time-std-dev: 500us
time-factor-under-load: 1.5
```

Upstream's own reference table puts a 1–3B model's TTFT at **80–130 ms on an L40S** and
inter-token latency at **12–18 ms**, which is where this profile lands.

### What this predicts, before it is run

Run 2 measured ~370-token prompts. Under this profile:

| | Prefill time |
|---|---|
| Nothing cached | `20ms + 370 × 350µs` = **149.5 ms** |
| 5 full blocks cached (320 tokens, the ceiling) | `20ms + 50 × 350µs` = **37.5 ms** |

**So a cache hit is worth about 112 ms**, where today it is worth zero.

The marginal difference between the two arms is the interesting one: 4.2 points of hit
ratio across a 370-token prompt is ~15.5 more tokens cached per request, or
`15.5 × 350µs` ≈ **5.4 ms saved per request** — bought with 95 µs of scheduling, a return
of roughly **57×**.

That is a prediction from the profile's arithmetic, not a result. Run 3 either lands near
it or it does not, and either outcome is worth writing down. Note also that
`kv-cache-transfer-time-per-token: 12us` finally gives P/D's KV transfer a real cost —
about 4.4 ms on a 370-token prompt — which is what makes the `nonCachedTokens` threshold
sweep in §4 a meaningful experiment rather than a trivially-always-split one.

This converts the repo's standing limitation — *"what it cannot prove: what a cache hit
is worth in wall-clock seconds"* — from a permanent caveat into a modelled one whose
parameters are written down and attributable. The lab could then say: *at an 8B-on-H100
prefill cost, a cache hit is worth N ms, and here is the load at which the scheduler's
95 µs stops paying for itself.*

**Two corrections this forces in the repo**, both to text that is currently public:

1. `README.md` says *"a simulated prefill is nearly free."* It is exactly free, by
   default, because the parameter was never set. Reword before anyone reads it.
2. `bench/README.md` reasons about latency as *"the simulator models prefill time rather
   than performing it — so a cache hit saves simulated work."* It models it as zero, so
   no work is saved. The conclusion drawn there was right for the wrong reason.

Re-run run 2 after adopting a profile. The hit-ratio result stands — that measurement
never depended on latency — but the latency columns need replacing rather than amending.

## 2. The cache-size sweep — turn the run-1 null result into a curve

Run 1 found nothing because the cache was too big to evict. That is currently narrated
in prose. It should be a graph.

Sweep `--kv-cache-size` across `16, 32, 64, 256, 1024` blocks, both arms, hit ratio on
the y-axis. Somewhere between 16 and 1024 the two lines converge — **that crossing point
answers "when is cache-aware routing worth deploying?"**, which is the question an
operator actually has and which no llm-d write-up answers with a number.

Cheap: no new components, one argument, five runs per arm.

## 3. Kill the EPP under load

`failureMode: FailOpen` is documented in `epp-scheduling.md` and has never been
exercised. Delete the EPP mid-benchmark and measure what the gateway does: requests
should keep succeeding, and the hit ratio should decay toward the round-robin baseline.

That is an availability experiment, not a performance one, and it is the one this lab is
uniquely positioned to run — it needs three replicas per role, a working control arm and
a cache-hit metric, all of which exist. It pairs directly with A2's restart test.

Worth extending: kill a **decode** pod mid-request and watch the sidecar; kill the
`render` service and watch both sides silently fall back to pseudo-hash tokenization,
which is a genuinely nasty failure because nothing errors.

## 4. Sweep the scorer weights

The README calls the weights "the policy... the first thing to experiment with," and
they have never been changed. `prefix-cache-scorer: 3` against `queue-scorer: 2` is
llm-d's opinion, not a measurement.

Sweep the prefix weight `0, 1, 3, 5, 10` with the others fixed. Expect hit ratio to rise
and tail latency to worsen as affinity beats load balancing — **the shape of that
trade-off is the deliverable**, and it is exactly the kind of tuning curve an SRE is
asked to produce.

Same experiment for `nonCachedTokens` on the P/D decider: `1` means split on any cold
token. At what threshold does moving prefill stop paying? (Needs §1 to have given the
transfer a non-zero cost, or the answer is trivially "always".)

## 5. Alerting on inference SLOs

The AI lab has a dashboard and zero alert rules. The musashi cluster has nine. The gap
is conspicuous, and closing it links the two labs into one story: *the same alerting
discipline, applied to a workload whose failure modes are different.*

Candidates this cluster can actually evaluate: TTFT p95 over a threshold; prefix cache
hit ratio below a baseline for 10m (cache locality collapsed — usually a routing fault,
not a capacity one); `vllm:kv_cache_usage_perc > 90%` sustained; EPP scrape down —
which, given `FailOpen`, is a **silent** degradation, precisely the class of alert that
earns its keep.

## 6. Multi-turn conversations

The benchmark sends persona plus one question. A real chat grows the prompt every turn,
which is where prefix caching does its best work and where cache-aware routing has the
most to win. Extending `ab-bench.sh` to append each response to the next request's
context would make the workload resemble the thing being optimised for.

## 7. Session-based routing as a third comparison

The router ships a `sessionid` data producer. Many production systems route by session
ID instead of by content — simpler, no tokenizer, no index, no ZMQ. Comparing it against
both prefix strategies answers a real deployment question: **how much of prefix-aware
routing's benefit can be had with a hash of a cookie?** If the answer is "most of it,"
that is a more useful finding than a third confirmation that prefix routing works.

## 8. Route by predicted latency

`predictedlatency` is another shipped producer and another llm-d well-lit path. Lower
priority: its value depends entirely on §1, since with zero-cost backends there is no
latency to predict.

---

# Suggested order for next week

| | Item | Why here |
|---|---|---|
| 1 | **Part 3 §1** — adopt a simulator latency profile | The check is done: the defaults **are** zero. This reframes everything below, unblocks A4's `peakPrefillThroughput`, and forces two corrections to public text. |
| 2 | **Part 1, A0–A3** — precise prefix-cache routing | The ask. Self-contained, but the model-server side needs a simulator image with #668 and the sequence fix (`pr668-seq0`, built locally; no release has both). |
| 3 | **Part 3 §3** — kill the EPP under load | Shares A2's restart harness. Strongest result per hour spent. |
| 4 | **Part 3 §2** — cache-size sweep | Cheap, and it finally graphs the lab's most interesting finding. |
| 5 | **Part 2** — agentgateway metrics | Small, and every latency panel improves. |

Items 1 and 2 are a day. Items 3 and 4 are a day. Everything else is a menu.

---

# Added after the original plan

Items that did not exist when this document was written, recorded so they are not lost.

## Gateway latency decomposition — the panels the scrape unlocks

`52-scrape-gateway.yaml` closes the last hole in the request path. What it buys is the
decomposition the dashboard has always implied and never shown: **time in the gateway,
time waiting on the EPP, time in the model server.**

Before writing panels, confirm which metric families the running gateway actually emits.
The first 30 lines of `/metrics` are xDS, tokio runtime and cgroup gauges — infrastructure,
not request data. Request and `gen_ai` metrics may appear further down, or may only
materialise once traffic of that type has flowed:

```bash
GW=$(kubectl -n llm-d get pods -o name | grep -i gateway | grep -v epp | head -1 | cut -d/ -f2)
IP=$(kubectl -n llm-d get pod "$GW" -o jsonpath='{.status.podIP}')
kubectl -n llm-d exec deploy/render -- curl -s "http://$IP:15020/metrics" \
  | grep -E '^# (HELP|TYPE)' | grep -viE 'xds|tokio|cgroup|config_synchronized'
```

### What this build actually emits — read off the endpoint, 2026-09-25

**The `gen_ai` family does not exist here.** No `agentgateway_gen_ai_server_time_to_first_token`,
no time-per-output-token, no client token usage. Those appear in agentgateway's
documentation but not in this build's `/metrics`, so the inference-aware metrics are a
newer or build-gated feature. **There is no independent TTFT measurement at the gateway**,
and the decomposition has to come from the generic request/upstream histograms.

What is present, with the help text verbatim:

| Metric | Type | Help text |
|---|---|---|
| `agentgateway_request_duration_seconds` | histogram | Duration of HTTP requests (seconds) |
| `agentgateway_request_processing_seconds` | histogram | **Duration from receiving an HTTP request to sending the primary outbound call** |
| `agentgateway_response_processing_seconds` | histogram | Duration from receiving the primary outbound response to sending the HTTP response |
| `agentgateway_upstream_call_duration_seconds` | histogram | Duration of outbound calls made by agentgateway |
| `agentgateway_upstream_connect_duration_seconds` | histogram | Duration to establish upstream connection |
| `agentgateway_requests` | counter | The total number of HTTP requests sent |
| `agentgateway_requests_shed` | counter | Downstream requests rejected by the in-flight request limit |
| `agentgateway_downstream_connections` / `_shed` | counter | connections established / closed by the limit |
| `agentgateway_response_bytes`, `_downstream_received_bytes`, `_downstream_sent_bytes` | counter | byte volumes |

Plus `agentgateway_build` (info), and a large family of `agentgateway_process_*` memory
gauges — rss, pss, swap, hugepages and so on — which are process introspection rather than
request data.

### The decomposition this gives, and the one open question

`request_processing_seconds` is *"from receiving an HTTP request to sending the primary
outbound call"*. **The ext_proc round trip to the endpoint picker happens inside that
window**, which makes it the scheduling cost measured from the gateway's side — an
independent check on the EPP's own 95 µs self-report. Two components timing the same
decision; disagreement would be a finding.

So, roughly:

```
request_duration_seconds
  ≈ request_processing_seconds      gateway + the EPP decision
  + upstream_call_duration_seconds  the model server
  + response_processing_seconds     gateway, on the way back
```

**Open question before writing panels: what labels do these histograms carry?**
`upstream_call_duration_seconds` is *"outbound calls"* — and the ext_proc call to the EPP
is itself an outbound call. If the series are labelled by target, the EPP call and the
backend call can be separated and the decomposition is clean. If not,
`upstream_call_duration_seconds` conflates the two and only the coarser split is
available. Check with:

```bash
kubectl -n llm-d exec deploy/render -- curl -s "http://$IP:15020/metrics" \
  | grep -E '^agentgateway_(requests|upstream_call_duration_seconds_count|request_processing_seconds_count)\{'
```

### Prometheus, for real this time

The Helm release is named `monitoring`, not `kube-prometheus-stack`:

```
statefulset.apps/prometheus-monitoring-kube-prometheus-prometheus
service/monitoring-kube-prometheus-prometheus   9090/TCP, 8080/TCP
```

Query it from inside the cluster rather than port-forwarding:

```bash
kubectl -n llm-d exec deploy/render -- curl -s \
  "http://monitoring-kube-prometheus-prometheus.monitoring:9090/api/v1/targets?state=active" \
  | tr ',' '\n' | grep -iE 'agentgateway|"health"'
```

## Verify the PodMonitor is actually selected

`podMonitorSelectorNilUsesHelmValues: false` means Prometheus takes every PodMonitor in
every namespace, so no label wiring is needed — but confirm the target appears and is UP
rather than assuming it did. An accepted `kubectl apply` says nothing about whether
Prometheus agreed to scrape it.

---

# Flux — GitOps for this cluster

Recorded 2026-09-26. It had been discussed and never written down, which is exactly how
something gets lost.

## Why Flux and not Argo CD

**Because musashi already runs Argo CD and Argo Rollouts.** Using the same tool twice
proves nothing; using the other one means the two labs together cover both major GitOps
implementations, and the comparison becomes something answerable from experience rather
than from documentation — reconciliation model, Helm handling, secret handling, what each
one does when the cluster and git disagree.

It also fits this cluster better on one axis: Flux has no UI to speak of, and this lab has
already decided Grafana's UI is never the only copy. A controller that reads git and
nothing else is consistent with that.

## What it would replace

Today every manifest reaches the cluster the same way:

```bash
vagrant upload manifests /home/vagrant/manifests k3s-server
kubectl apply -f ~/manifests/...
```

That is the weakest operational part of the lab. The README already argues the manifests
live in git "so that a rebuilt cluster is a `vagrant up` plus an apply, not an archaeology
exercise" — Flux finishes that sentence by removing the apply.

## The part that is actually work: the Helm releases

The `InferencePool` and endpoint picker are **not** manifests. They come from an OCI Helm
chart applied by hand:

```bash
helm upgrade -i sim-pool oci://ghcr.io/llm-d/charts/llm-d-router-gateway \
  --version v0.10.0 --namespace llm-d -f ~/manifests/epp-precise-values.yaml
```

Under Flux that becomes a `HelmRepository` of `type: oci` plus a `HelmRelease` carrying the
values inline or from a ConfigMap. Same for agentgateway and kube-prometheus-stack, which
are also hand-installed charts. Three chart installs to convert, and OCI repositories are
the fiddly case — worth expecting a session on that alone.

**One thing Flux fixes for free:** `helm upgrade` does not restart the EPP, because plugin
config lands in a ConfigMap that the EPP reads once at startup. That has cost this project
real time twice. Flux can be told to roll the Deployment when the ConfigMap changes, which
turns a recurring manual step into a property of the system.

## The tension worth resolving before starting

**GitOps assumes one desired state. This lab deliberately has several.**

`manifests/` currently holds `epp-values.yaml`, `epp-pd-values.yaml`,
`epp-precise-values.yaml`, `epp-sweep-values.yaml.tmpl` and `epp-nopd-values.yaml.tmpl` —
five competing configurations, swapped by `bench/weight-sweep.sh` and
`bench/restart-test.sh` mid-experiment. A reconciler would fight that: the sweep script
changes the release, Flux notices drift and changes it back, and the benchmark measures
whichever won.

Three ways out, and the choice should be made deliberately rather than discovered:

1. **Flux owns the baseline; experiments suspend it.** `flux suspend hr sim-pool` before a
   sweep, `flux resume` after. Simple, and the suspend/resume becomes part of the
   experiment protocol — which is arguably an improvement, since it makes "the cluster is
   deliberately off-spec right now" explicit.
2. **Flux owns everything except the EPP release.** The stack reconciles; the component
   under experiment stays manual. Honest, and slightly unsatisfying.
3. **Each experiment is a git branch.** Purest GitOps, worst ergonomics for a sweep of four
   points.

(1) is probably right. Whichever is chosen, **write down why** — a reader who sees
`flux suspend` in a benchmark script deserves to know it is intentional.

## Secrets, which this lab currently dodges

Two credentials are deliberately not in git: the k3s join token (generated into a
gitignored file) and Grafana's admin password (set in the UI, never committed, and
therefore lost on every pod restart — see the Grafana item above).

Flux plus SOPS with an age key would let both be committed **encrypted**, which fixes the
Grafana password permanently instead of documenting it as a known annoyance. That is a
genuinely better answer than a PVC, and it is the standard pattern rather than something
invented here.

## Rough sequence

| | Step |
|---|---|
| 1 | `flux bootstrap github` against `igfurlan/k3s-llmd-lab`, or a separate ops repo if mixing lab code and cluster state feels wrong |
| 2 | Move the plain manifests — namespace, render, simulators, gateway, ollama, the round-robin control, the monitoring scrape configs and dashboards — into a `Kustomization` |
| 3 | Convert the three Helm installs to `HelmRepository` + `HelmRelease`, OCI last |
| 4 | Decide and document the experiment/reconciliation policy above |
| 5 | SOPS + age for the join token and the Grafana password |
| 6 | Prove it: delete something Flux owns and watch it come back. A GitOps install that has never been tested by deleting a resource is a control plane nobody has confirmed is operating — the same failure mode as the P/D sidecar and the KV-events socket |

## What this is not

Not a prerequisite for anything else in this backlog. Every experiment above runs fine
against hand-applied manifests. This is an operations increment and a portfolio one — it
makes the lab reproducible by a stranger, and it lets the two labs together say something
about Argo *and* Flux rather than only one of them.
