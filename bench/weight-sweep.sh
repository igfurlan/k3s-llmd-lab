#!/usr/bin/env bash
#
# Sweep the prefill profile's prefix-cache-scorer : queue-scorer ratio and
# measure what it does to cache locality and to load spread.
#
#   ~/bench/weight-sweep.sh <prefix_weight> <queue_weight> [requests] [conc] [users]
#
# WHY THIS EXISTS
#   Run 3 put 100% of prefill traffic on one of three pods, with two idle, and
#   its p90 sat at 2x its p50. Nothing about the routing config had changed
#   since run 2, which had spread 15k-44k tokens across all three -- what
#   changed was that requests started costing real time, which closed a
#   feedback loop: the first pod to hold the shared prefix stays warm, keeps
#   winning, and queue-scorer at weight 1 cannot outvote prefix-cache-scorer at
#   weight 3 however deep its queue grows.
#
#   So the hot spot may be three integers rather than a missing component.
#   This script is the cheapest test of that, and it runs before the larger
#   precise-prefix-cache increment because it might make it unnecessary.
#
# WHAT IT DOES, IN ORDER
#   1. renders manifests/epp-sweep-values.yaml.tmpl with the two weights
#   2. helm upgrade -- which restarts the EPP, clearing its prefix index
#   3. rollout restart of both simulators -- which clears their KV caches
#   4. runs ab-bench.sh against the EPP path
#
#   Steps 2 and 3 matter: a warm cache or a warm index carried over from the
#   previous point in the sweep is the easiest way to get a flattering number
#   for whichever ratio ran second.
#
# WHAT TO READ IN THE OUTPUT
#   - hit ratio            does locality survive a lower ratio?
#   - the per-pod table    does prefill spread across all three?
#   - p50 vs p90           the gap is queueing; it should close as it spreads
#
# CONCURRENCY IS NOT OPTIONAL HERE -- READ THIS BEFORE SWEEPING
#   The first sweep (3:1, 3:3, 3:8, 1:8) moved the hit ratio by 0.54 points
#   total, and the load spread non-monotonically: 1 pod, 2, 2, 1. The reason is
#   that queue-scorer scores on WaitingQueueSize, and at concurrency 4 over
#   three pods with max-num-seqs 4 the pool has capacity 12 and nothing ever
#   waits. Every candidate scored exactly 1, so the queue term was a CONSTANT
#   added to every pod, which cancels in the argmax. Sweeping the weight of a
#   scorer that returns a constant is sweeping nothing.
#
#   For queue-scorer to carry signal, offered concurrency must exceed
#   replicas x max-num-seqs. With 3 prefill pods at max-num-seqs 4 that means
#   >12 -- run the sweep at concurrency 16 or 24:
#
#     ~/bench/weight-sweep.sh 3 1 480 24 6
#
#   Below that threshold this script measures a startup race: all caches begin
#   cold, every prefix score is 0, the first request breaks a three-way tie
#   arbitrarily, and whichever pod warms first keeps winning.
#
set -euo pipefail

PREFIX_W="${1:?usage: weight-sweep.sh <prefix_weight> <queue_weight> [requests] [conc] [users]}"
QUEUE_W="${2:?usage: weight-sweep.sh <prefix_weight> <queue_weight> [requests] [conc] [users]}"
REQS="${3:-240}"
CONC="${4:-4}"
USERS="${5:-6}"

NS=llm-d
TMPL="${HOME}/manifests/epp-sweep-values.yaml.tmpl"
RENDERED="${HOME}/manifests/.epp-sweep-${PREFIX_W}-${QUEUE_W}.yaml"
CHART="oci://ghcr.io/llm-d/charts/llm-d-router-gateway"
CHART_VERSION="v0.10.0"

[ -f "$TMPL" ] || { echo "missing template: $TMPL (did you vagrant upload manifests?)" >&2; exit 1; }
[ -x "${HOME}/bench/ab-bench.sh" ] || chmod +x "${HOME}/bench/ab-bench.sh"

echo "=============================================================="
echo " WEIGHT SWEEP POINT: prefix-cache-scorer=${PREFIX_W}  queue-scorer=${QUEUE_W}"
echo "   ratio ${PREFIX_W}:${QUEUE_W}   (run 3 baseline was 3:1)"
echo "=============================================================="

# 1. render -------------------------------------------------------------
sed -e "s/__PREFIX_W__/${PREFIX_W}/" -e "s/__QUEUE_W__/${QUEUE_W}/" "$TMPL" > "$RENDERED"
if grep -q '__PREFIX_W__\|__QUEUE_W__' "$RENDERED"; then
  echo "render failed: placeholders remain in $RENDERED" >&2; exit 1
fi
echo "-- rendered prefill profile:"
# `set -e` + `pipefail` + a grep that matches nothing = the script dies here.
# Every grep in this script that is only there to PRINT something must be
# protected, or a cosmetic step takes the experiment down with it.
{ sed -n '/- name: prefill/,/- name: decode/p' "$RENDERED" \
    | grep -E 'name: prefill|pluginRef|weight' | sed 's/^/     /'; } || true

# 2. apply --------------------------------------------------------------
echo "-- helm upgrade"
helm upgrade -i sim-pool "$CHART" --version "$CHART_VERSION" \
  --namespace "$NS" -f "$RENDERED" >/dev/null

# `helm upgrade` returns before the deployment controller has created the new
# ReplicaSet, so calling `rollout status` straight after can observe the OLD
# generation, find it complete, and return success instantly. The first version
# of this script did exactly that, and then read the previous point's logs.
#
# An explicit restart makes the new rollout deterministic rather than racing it.
echo "-- restarting the EPP (clears its prefix index) and waiting for it"
kubectl -n "$NS" rollout restart deploy/sim-pool-epp >/dev/null
kubectl -n "$NS" rollout status deploy/sim-pool-epp --timeout=180s

# Verify from the ConfigMap the EPP mounts, NOT from its logs: the scoring
# debug lines only appear once traffic arrives, so a fresh pod has none, and
# grepping logs either matches nothing or matches the pod before it.
#
# Pull the config by KEY rather than by label. The chart's label scheme is not
# something to guess at, and `get cm -o yaml` renders the nested plugin YAML
# with escaped newlines on one line, which defeats a sed line-range. jsonpath
# hands back the raw string instead.
#
# The whole block is non-fatal: verification must never be able to kill the
# run it is verifying.
echo "-- prefill weights as they exist in the mounted config:"
set +e
EPP_CFG=$(kubectl -n "$NS" get cm -o jsonpath='{range .items[*]}{.data.pd-plugins\.yaml}{end}' 2>/dev/null)
if [ -n "$EPP_CFG" ]; then
  printf '%s\n' "$EPP_CFG" \
    | sed -n '/- name: prefill/,/- name: decode/p' \
    | grep -E 'name: prefill|pluginRef|weight' | sed 's/^/     /'
else
  echo "     (could not read the plugins ConfigMap -- verify by hand with:"
  echo "      kubectl -n $NS get cm -o jsonpath='{range .items[*]}{.data.pd-plugins\\.yaml}{end}')"
fi
set -e
echo "   (expected: prefix-cache-scorer=${PREFIX_W}, queue-scorer=${QUEUE_W})"

# 3. clear the caches ---------------------------------------------------
echo "-- restarting simulators to clear KV caches"
kubectl -n "$NS" rollout restart deploy/sim-prefill deploy/sim-decode >/dev/null
kubectl -n "$NS" rollout status deploy/sim-prefill --timeout=300s
kubectl -n "$NS" rollout status deploy/sim-decode  --timeout=300s
sleep 15

# 4. measure ------------------------------------------------------------
"${HOME}/bench/ab-bench.sh" /v1/chat/completions "$REQS" "$CONC" "$USERS"

echo
echo "  ^ point ${PREFIX_W}:${QUEUE_W} -- record hit ratio, the per-pod spread,"
echo "    and the p50/p90 gap in bench/README.md before running the next point."
