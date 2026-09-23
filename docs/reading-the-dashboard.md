# Reading the dashboard

A dashboard that only tells you the system is alive is wallpaper. Each panel here
exists because it answers a question that changes a decision — which knob to turn,
which pod to scale, which assumption to stop trusting.

This is that mapping: **what you see → what it means → what to do.**

Values quoted as "typical" come from this lab on 2026-09-23, three nodes of 4 vCPU
and 6 GB, two simulated model servers and one real ollama.

---

## 1. Prefix cache hit ratio

`sum(rate(vllm:prefix_cache_hits_total)) / sum(rate(vllm:prefix_cache_queries_total))`

**The single most important number on the page.** It is the fraction of prompt
tokens that did not have to be computed, and prefix-aware routing exists to raise
it. Every point of hit ratio is prefill work that never happened.

| You see | It means | Do this |
|---|---|---|
| Ratio rising as traffic repeats | Routing is keeping related prompts on the same pod. Working as designed | Nothing |
| **Near zero with repetitive traffic** | Requests that share a prefix are being scattered across pods | Raise `prefix-cache-scorer`'s weight; check the tokenizer is shared (see below) |
| Ratio **collapses when you add replicas** | Classic scatter: more pods, same prompts, each cache colder | Scale in, or accept it and raise the cache-affinity weight. More replicas is not free for cache-bound workloads |
| **Decode high, prefill low** (33% vs 7% here) | Normal for this shape. Repeated prompts hit decode; prefill sees cold prefixes because the decider only sends it work that *isn't* cached | Nothing. This is the split doing its job |
| Both roles at zero despite identical prompts | The two sides are hashing different tokens | Check the render service is reachable and that `--block-size` matches the router's `blockSizeTokens`. A mismatch here fails silently |

**The trap:** a prompt shorter than one block can never register a hit. At
`block-size 64`, a 109-token prompt tops out at 64 cached tokens — the trailing
45 are a partial block and are recomputed every time. If your hit ratio is
stubbornly low, check your prompt lengths against your block size before
rearranging the scheduler.

---

## 2. Prefill / decode split decisions

`sum by (decision_type) (rate(llm_d_epp_disagg_decision_total))`

Disaggregation buys parallelism and pays for it with a KV cache transfer. This
panel shows whether you are buying anything.

| You see | It means | Do this |
|---|---|---|
| A healthy mix of split and `decode-only` | The decider is discriminating: cold prompts split, cached ones don't | Nothing |
| **100% `decode-only`** | Nothing is ever being disaggregated. Either everything is cached, or the threshold is too high — or P/D silently never enabled | Check the EPP log for `No deciders.prefill configured`. Then lower `nonCachedTokens` |
| **100% split, with short prompts** | You are paying a KV transfer on every request to avoid a prefill that was cheap anyway | Raise `nonCachedTokens`, or set `promptTokens` so short prompts never split |
| Split rate rises while TTFT rises with it | The transfer costs more than the prefill it avoids — real on a slow network, common on a lab network | Raise the threshold. Disaggregation is not free and is not always right |

**The decision this panel drives:** whether P/D is worth running at all for *your*
traffic. Long, diverse prompts → yes. Short, repetitive ones → the split is
overhead, and the honest answer is to turn it off.

---

## 3. Scheduling cost, and plugin cost

`histogram_quantile(0.95, ... llm_d_epp_scheduler_e2e_duration_seconds_bucket)`

Smart routing sits **in** the request path. This panel is its invoice.

| You see | It means | Do this |
|---|---|---|
| Scheduling ≈ 95 µs against TTFT 23.8 ms (~0.4%) | The intelligence is essentially free | Nothing. This is the ratio that justifies the architecture |
| Scheduling above ~5% of TTFT | The scorers cost real latency | Open the per-plugin panel and find the expensive one |
| One plugin dominating the plugin panel | Usually a prefix indexer with a large index, or a metrics source scraping slow endpoints | Drop that plugin from the profile and measure the hit ratio you lose. Keep it only if it earns its cost |
| Scheduling p95 spiking while p50 is flat | Contention or GC in the EPP, not a systematic cost | Give the EPP more CPU before touching the plugin set |

**Keep the ratio, not the absolute number.** 95 µs is meaningless alone; 95 µs
against a 24 ms TTFT is the finding.

---

## 4. KV cache utilisation by role

`max by (llm_d_ai_role, pod) (vllm:kv_cache_usage_perc)`

| You see | It means | Do this |
|---|---|---|
| Flat and low | Plenty of headroom | Nothing |
| **One pod near 1.0 while a sibling is idle** | Routing is concentrating work — cache affinity is outvoting load | Raise `kv-cache-utilization-scorer`'s weight in the decode profile |
| All decode pods climbing together | Genuine capacity pressure | Scale **decode** replicas. Not prefill — see below |
| Sawtooth (fills, drops, fills) | Cache eviction churn: the working set exceeds capacity | More KV cache per pod, or more pods. Expect the hit ratio to sag until it fits |

---

## 5. Queue depth by role

`vllm:num_requests_running` and `..._waiting`

`waiting` is the one that matters: **running** is throughput, **waiting** is a
customer experiencing latency.

| You see | It means | Do this |
|---|---|---|
| `waiting` at 0 | You have capacity | Nothing |
| `waiting` sustained above 0 on **all** pods of a role | That phase is saturated | Scale that role's replicas |
| `waiting` high on **one** pod only | A routing imbalance, not a capacity problem | Raise `queue-scorer`'s weight. Adding pods will not fix a distribution fault |
| `waiting` high on decode, prefill idle | The split is landing work unevenly, or decode is genuinely the bottleneck | Scale decode alone — the whole point of disaggregation |

---

## 6. Token throughput by role

`rate(vllm:prompt_tokens_total)` and `rate(vllm:generation_tokens_total)`

Prompt tokens are consumed by prefill; generation tokens are produced by decode.
Which pod each lands on tells you whether disaggregation is actually happening.

| You see | It means | Do this |
|---|---|---|
| Generation ≈ 0 on prefill, high on decode | The roles are separated correctly | Nothing |
| Generation appearing on **prefill** | Prefill is serving whole requests, so the split is bypassed | Check the routing sidecar is present and the decider is firing |
| Prompt tokens high on decode | Decode is doing its own prefill — normal whenever a split is skipped | Cross-check the decisions panel; if splits should be happening, chase that |

**The capacity decision this unlocks:** prefill is compute-bound, decode is
memory-bandwidth-bound. Watch which throughput line saturates first and scale
*that role only*. Scaling both together is the habit disaggregation exists to
break.

---

## 7. TTFT and request duration

`llm_d_epp_request_ttft_seconds` and `llm_d_epp_request_duration_seconds`, both at
the router — so they include scheduling, any remote prefill, and the KV transfer.
This is what a caller feels.

| You see | It means | Do this |
|---|---|---|
| TTFT flat while hit ratio rises | Caching is working and latency is stable | Nothing |
| **TTFT rises with the split rate** | Remote prefill is costing more than it saves | Raise `nonCachedTokens` |
| TTFT rises with queue depth | Saturation, not routing | Scale the saturated role |
| Duration ≫ TTFT | Long generations. Normal, and a decode-capacity signal | Watch decode's KV utilisation |
| TTFT rises while everything else is flat | Suspect the host, not the cluster | On this lab: check `dmesg \| grep -c hrtimer` on the nodes. A descheduled guest looks exactly like a slow application |

---

## 8. Ready endpoints

`max(llm_d_epp_ready_endpoints)`

Small panel, sharp question: **how many pods can the picker actually choose
between?**

| You see | It means | Do this |
|---|---|---|
| Equals your model server count | Healthy | Nothing |
| Drops by one, traffic unaffected | A pod went NotReady and routing silently narrowed | Investigate the pod. Nothing else will alert you |
| Drops to zero | `failureMode: FailOpen` means requests still flow — round-robin, cache-blind | Urgent. The system looks fine and every routing decision has stopped happening |

That last row is the one to internalise: **FailOpen converts an outage into a
silent quality regression.** This panel and the hit ratio are the only two places
it shows up.

---

## 9. CPU and memory — simulated vs real

cAdvisor series, because ollama publishes no Prometheus metrics at all.

This panel exists for honesty. The simulators cost almost nothing; ollama burns
real CPU because it is really doing the work. Seeing both on one chart is the
clearest statement of what is modelled and what is measured here — and it is a
reminder that every `vllm:*` panel above is describing simulated behaviour with
real plumbing.

---

## Cross-panel diagnoses

Single panels mislead. These combinations do not.

**Hit ratio down + split rate up + TTFT up.** Prompt diversity rose. The cache is
missing, so the decider splits more, so more KV transfers happen. Nothing is
broken — the workload changed. Decide whether prefill needs more replicas.

**Hit ratio down + split rate down.** Contradictory, so suspect the plumbing:
the router thinks everything is cached while the servers disagree. Check that
both sides tokenize identically and that block sizes match.

**Queue depth up + CPU flat.** The pods are not working, they are waiting. On a
VM lab, suspect the hypervisor before the application — this is precisely the
signature that cost this project two days on VirtualBox: load average 13–19 with
73% idle CPU.

**Everything flat, `ready_endpoints` below expected.** Traffic is being served by
fewer pods than you think, and the dashboard's averages are hiding it.

---

## What this cannot tell you

- **Answer quality.** Nothing here knows whether the model said anything useful.
- **Whether the cache hits were worth having.** A hit on a prefix nobody reuses
  again is a coincidence, not a design.
- **Cost.** No dollars, no GPU hours. On real hardware that is the column that
  decides whether any of this pays for itself.

A dashboard measures the machine. Whether the machine should be doing this at all
is still a human question.
