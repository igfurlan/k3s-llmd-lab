#!/usr/bin/env bash
#
# Does the router still know where the caches are after it restarts?
#
#   ~/bench/restart-test.sh <approx|precise> [trials]
#
# THE ONE THING THE APPROXIMATE PRODUCER STRUCTURALLY CANNOT DO
#   The approximate producer builds its index from its OWN past routing
#   decisions, and that index lives only in EPP memory. Restart the EPP and it
#   is gone -- the router relearns from live traffic, and until it does it is
#   guessing.
#
#   The precise producer subscribes to the model servers' ZMQ events and, on
#   startup, replays buffered events from each pod's replay socket (5559). The
#   servers still hold the blocks; the router asks them what they have.
#
#   So: warm ONE prefix, restart ONLY the EPP -- never the simulators, whose
#   caches must survive -- and send the same prefix again. Did it land back on a
#   pod that still holds the blocks?
#
# WHY IT IS CATEGORICAL, AND WHY THAT MATTERS HERE
#   The hit-ratio comparison is a point or two on a harness whose latency and
#   pod distribution vary by more than that between identical runs (see
#   bench/README.md, "The repeat"). This asks a yes/no question per trial and
#   counts. Noise becomes a count instead of hiding inside an average.
#
#   Null hypothesis, stated: with three candidate pods a router that knows
#   nothing still lands correctly about one trial in three by luck.
#
# WHAT THE FIRST VERSION OF THIS SCRIPT GOT WRONG
#   It warmed all N prefixes first, then restarted once. With 16-block caches
#   (1024 tokens) and ~640-token prompts, two prompts do not fit, so each trial
#   evicted the one before it and five of six trials reported warm=0 -- the
#   precondition had failed and the script ran on anyway, "measuring" retention
#   of caches that were never established.
#
#   Fixed three ways: one trial at a time with the caches cleared between them,
#   a prompt sized to fit, and a precondition check that refuses to score a
#   trial that did not warm.
#
set -euo pipefail

MODE="${1:?usage: restart-test.sh <approx|precise> [trials]}"
TRIALS="${2:-5}"
case "$MODE" in approx|precise) ;; *) echo "mode must be approx or precise" >&2; exit 1;; esac

NS=llm-d
GW="${GW:-http://192.168.58.11}"
MODEL="Qwen/Qwen2.5-1.5B-Instruct"
TMPL="${HOME}/manifests/epp-nopd-values.yaml.tmpl"
RENDERED="${HOME}/manifests/.epp-nopd-${MODE}.yaml"
CHART="oci://ghcr.io/llm-d/charts/llm-d-router-gateway"
CHART_VERSION="v0.10.0"

[ -f "$TMPL" ] || { echo "missing template: $TMPL" >&2; exit 1; }

# ---------------------------------------------------------------- render ----
# The two arms differ in exactly one thing: whether a precise producer exists
# and the scorer is bound to it. The approx arm names no producer at all, so
# the data layer auto-creates the approximate one -- which is the default
# behaviour this lab ran for weeks without noticing.
if [ "$MODE" = precise ]; then
  PRODUCER_PLUGINS=$(cat <<'P'
        - type: token-producer
          parameters:
            modelName: Qwen/Qwen2.5-1.5B-Instruct
            vllm:
              url: "http://render:8082"
        - type: endpoint-notification-source
        - type: precise-prefix-cache-producer
          parameters:
            tokenProcessorConfig:
              blockSizeTokens: 64
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
P
)
  SCORER_PARAMS=$(cat <<'P'
          parameters:
            prefixMatchInfoProducerName: precise-prefix-cache-producer
P
)
  DATA_LAYER=$(cat <<'P'
        dataLayer:
          sources:
          - pluginRef: endpoint-notification-source
            extractors:
            - pluginRef: precise-prefix-cache-producer
P
)
else
  PRODUCER_PLUGINS=""
  SCORER_PARAMS=""
  DATA_LAYER=""
fi

python_free_render() {
  awk -v prod="$PRODUCER_PLUGINS" -v sco="$SCORER_PARAMS" -v dl="$DATA_LAYER" '
    /^__PRODUCER_PLUGINS__$/ { if (prod != "") print prod; next }
    /^__SCORER_PARAMS__$/    { if (sco  != "") print sco;  next }
    /^__DATA_LAYER__$/       { if (dl   != "") print dl;   next }
    { print }
  ' "$TMPL"
}
python_free_render > "$RENDERED"
if grep -q '__PRODUCER_PLUGINS__\|__SCORER_PARAMS__\|__DATA_LAYER__' "$RENDERED"; then
  echo "render failed: markers remain in $RENDERED" >&2; exit 1
fi

echo "=============================================================="
echo " EPP RESTART TEST -- mode=${MODE}  trials=${TRIALS}"
echo "=============================================================="
echo "-- applying no-P/D config and restarting the EPP"
helm upgrade -i sim-pool "$CHART" --version "$CHART_VERSION" \
  --namespace "$NS" -f "$RENDERED" >/dev/null
kubectl -n "$NS" rollout restart deploy/sim-pool-epp >/dev/null
kubectl -n "$NS" rollout status deploy/sim-pool-epp --timeout=180s >/dev/null

# ------------------------------------------------------------- helpers ----
# ~300 tokens: five 64-token blocks, so one prompt fits comfortably inside a
# 16-block cache with room for the chat template. The previous ~640-token
# prompt did not leave room for anything else.
filler() {
  local seed="$1" i out=""
  for i in $(seq 1 55); do out+="subject${seed}item${i} "; done
  printf '%s' "$out"
}

cached_tokens() {
  curl -s --max-time 30 "${GW}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"$1\"}],\"max_tokens\":4}" \
    | grep -o '"cached_tokens":[0-9]*' | head -1 | cut -d: -f2
}

clear_caches() {
  kubectl -n "$NS" rollout restart deploy/sim-prefill deploy/sim-decode >/dev/null
  kubectl -n "$NS" rollout status deploy/sim-prefill --timeout=300s >/dev/null
  kubectl -n "$NS" rollout status deploy/sim-decode  --timeout=300s >/dev/null
  sleep 12
}

echo "-- producers actually running:"
kubectl -n "$NS" logs deploy/sim-pool-epp 2>/dev/null \
  | grep -oE '(precise|approx)-prefix-cache-producer' | sort -u | sed 's/^/     /' || true
if [ "$MODE" = precise ]; then
  echo "   (expect precise only -- approx appearing here means something still"
  echo "    consumes PrefixCacheMatchInfo and the arms are not clean)"
fi

VALID=0; RETAINED=0
for t in $(seq 1 "$TRIALS"); do
  echo "--------------------------------------------------------------"
  echo " trial ${t}: clearing caches"
  clear_caches
  P="$(filler "$t")"

  cold=$(cached_tokens "$P"); cold="${cold:-0}"
  warm=$(cached_tokens "$P"); warm="${warm:-0}"
  printf "   warm-up: cold=%s warm=%s\n" "$cold" "$warm"

  # PRECONDITION. A trial that never cached cannot tell us anything about
  # whether a cache survived, and scoring it anyway is how the first version of
  # this script produced a meaningless 3/6.
  if [ "$warm" -le 0 ]; then
    echo "   VOID -- prefix never cached, trial not scored"
    continue
  fi
  VALID=$((VALID+1))

  kubectl -n "$NS" rollout restart deploy/sim-pool-epp >/dev/null
  kubectl -n "$NS" rollout status deploy/sim-pool-epp --timeout=180s >/dev/null
  sleep 10   # let the precise producer replay from each pod's 5559 socket

  after=$(cached_tokens "$P"); after="${after:-0}"
  if [ "$after" -gt 0 ]; then
    RETAINED=$((RETAINED+1)); echo "   after restart: cached_tokens=${after}  RETAINED"
  else
    echo "   after restart: cached_tokens=0  lost"
  fi
done

echo "=============================================================="
echo " mode=${MODE}   RETAINED ${RETAINED} / ${VALID} valid trials  (${TRIALS} attempted)"
echo
echo "   Chance is about 1 in 3, with three candidate pods."
echo "   Run both modes and compare the two scores; a single score"
echo "   on its own says very little."
echo "=============================================================="
