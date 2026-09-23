#!/usr/bin/env bash
#
# A/B load generator for the llm-d lab.
#
#   ./ab-bench.sh <base-url-path> [requests] [concurrency] [users]
#
#   ./ab-bench.sh /v1/chat/completions      # arm A: gateway -> EPP -> InferencePool
#   ./ab-bench.sh /rr/v1/chat/completions   # arm B: gateway -> Service -> round robin
#
# THE WORKLOAD SHAPE IS THE EXPERIMENT.
#
# Each request is:
#
#   [ shared system prompt ~250 tokens ][ per-user persona ~40 ][ question ~20 ]
#
# which is what real LLM traffic looks like: a long instruction block every
# caller shares, a per-conversation preamble, and a short varying question. That
# shape is precisely where prefix caching pays — the first two parts are
# identical across a user's turns, so a router that keeps a user's requests on
# one pod skips recomputing them, and a router that scatters them cannot.
#
# A benchmark of unique random prompts would show nothing, because there would
# be nothing to cache. A benchmark of one identical prompt would show everything
# and prove nothing. This sits where the decision actually lives.
#
set -euo pipefail

PATH_SUFFIX="${1:?usage: ab-bench.sh <path> [requests] [concurrency] [users]}"
REQUESTS="${2:-240}"
CONCURRENCY="${3:-4}"
USERS="${4:-6}"

# Cache counters are read straight off the model servers, before and after the
# run, rather than queried from Prometheus.
#
# Why: the first version of this script asked Prometheus for
# `increase(...[10m])` immediately after each arm. Every arm returned the
# identical ratio, because a 60-request run finishes in under a second, the
# scrape interval is 15s, and a 10-minute window spans both arms anyway. The
# number was real and answered a question nobody asked.
#
# Reading the counters directly makes the delta exact and independent of scrape
# timing — and gives per-pod totals, which is the measurement that actually
# separates the two arms: round-robin scatters a user's turns, prefix-aware
# routing concentrates them.
snapshot() {
  local ip
  for ip in $(kubectl -n llm-d get pods -l app=sim -o jsonpath='{range .items[*]}{.status.podIP}{" "}{end}'); do
    curl -s --max-time 5 "http://${ip}:8000/metrics" \
      | awk -v ip="${ip}" '
          /^vllm:prefix_cache_hits_total/    { h = $2 }
          /^vllm:prefix_cache_queries_total/ { q = $2 }
          END { printf "%s %d %d\n", ip, h + 0, q + 0 }'
  done
}

HOST="${HOST:-http://192.168.58.11}"
MODEL="${MODEL:-Qwen/Qwen2.5-1.5B-Instruct}"
URL="${HOST}${PATH_SUFFIX}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ~250 tokens, identical for every request in both arms.
SYSTEM=$(cat <<'EOF'
You are an infrastructure assistant embedded in a Kubernetes platform team's tooling. You answer questions about distributed inference serving, Kubernetes networking, and observability. Follow these rules in every answer. Be concrete and prefer specifics over generalities. When a question involves a trade-off, name both sides of it and say which conditions favour each. When you are uncertain, say so plainly rather than hedging with vague language. Never invent metric names, flag names, or API fields; if you do not know the exact name, describe the concept and say the name should be verified. Prefer short paragraphs over bullet lists unless the user asks for a list. Assume the reader is an experienced engineer who does not need basic Kubernetes concepts explained, but who may be new to large language model serving specifically. When discussing performance, distinguish clearly between latency experienced by a caller and throughput measured across a fleet, because optimising one frequently costs the other. If a question can be answered by pointing at a specific metric or log line, point at it rather than describing what one might generally look for.
EOF
)

# Per-user preamble. Requests from the same user share system + persona, so
# their common prefix is ~290 tokens — several 64-token blocks deep.
persona() {
  case "$1" in
    0) echo "I run the platform team for a company serving a code completion model to about two thousand developers." ;;
    1) echo "I am migrating a retrieval augmented generation service from a single GPU server onto a Kubernetes cluster." ;;
    2) echo "I operate a customer support chatbot where conversations are long and the system prompt is enormous." ;;
    3) echo "I am benchmarking inference gateways for a procurement decision and need defensible numbers." ;;
    4) echo "I maintain the observability stack and I am adding dashboards for a new inference platform." ;;
    *) echo "I am an SRE on call for an inference service that has been paging overnight for latency spikes." ;;
  esac
}

question() {
  case "$(( $1 % 5 ))" in
    0) echo "What should I watch first when latency rises?" ;;
    1) echo "How do I decide whether to add replicas?" ;;
    2) echo "Which metric tells me caching is working?" ;;
    3) echo "What would you check before changing any configuration?" ;;
    *) echo "How do I tell a routing problem from a capacity problem?" ;;
  esac
}

# One request: writes "<http_code> <seconds>" to a per-request file.
# Exported so xargs subshells can call it.
fire() {
  local i="$1" user q body start end
  user=$(( i % USERS ))
  q="$(question "$i") (turn $(( i / USERS )))"
  body=$(cat <<JSON
{"model":"${MODEL}","messages":[{"role":"system","content":$(printf '%s' "${SYSTEM}" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')},{"role":"user","content":"$(persona "$user") ${q}"}],"max_tokens":48}
JSON
)
  printf '%s' "$body" > "${WORKDIR}/req-${i}.json"
  curl -s -o /dev/null \
       -w '%{http_code} %{time_total}\n' \
       -H 'Content-Type: application/json' \
       --max-time 60 \
       -d "@${WORKDIR}/req-${i}.json" \
       "${URL}" > "${WORKDIR}/res-${i}" || echo "000 0" > "${WORKDIR}/res-${i}"
}
export -f fire persona question
export WORKDIR URL MODEL SYSTEM USERS

echo "=============================================================="
echo " URL:         ${URL}"
echo " requests:    ${REQUESTS}   concurrency: ${CONCURRENCY}   users: ${USERS}"
echo " started:     $(date -u +%Y-%m-%dT%H:%M:%SZ)   <- note this for Grafana"
echo "--------------------------------------------------------------"

snapshot > "${WORKDIR}/before"

START_EPOCH=$(date -u +%s)
seq 0 $(( REQUESTS - 1 )) | xargs -P "${CONCURRENCY}" -I{} bash -c 'fire {}'
END_EPOCH=$(date -u +%s)

snapshot > "${WORKDIR}/after"

cat "${WORKDIR}"/res-* > "${WORKDIR}/all"

OK=$(awk '$1 == 200' "${WORKDIR}/all" | wc -l)
BAD=$(awk '$1 != 200' "${WORKDIR}/all" | wc -l)

# Latency percentiles from the sorted list of successful requests.
awk '$1 == 200 {print $2}' "${WORKDIR}/all" | sort -n > "${WORKDIR}/times"
COUNT=$(wc -l < "${WORKDIR}/times")
pct() {
  local p="$1" idx
  idx=$(awk -v c="${COUNT}" -v p="${p}" 'BEGIN{ i=int(c*p/100); if(i<1) i=1; print i }')
  sed -n "${idx}p" "${WORKDIR}/times"
}

echo " finished:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo " elapsed:     $(( END_EPOCH - START_EPOCH ))s"
echo " ok / failed: ${OK} / ${BAD}"
if [ "${COUNT}" -gt 0 ]; then
  printf " latency p50: %ss\n" "$(pct 50)"
  printf " latency p90: %ss\n" "$(pct 90)"
  printf " latency p99: %ss\n" "$(pct 99)"
  printf " mean:        %ss\n" "$(awk '{s+=$1} END{printf "%.4f", s/NR}' "${WORKDIR}/times")"
fi
echo "--------------------------------------------------------------"
echo " PREFIX CACHE, measured from the model servers themselves"
echo "--------------------------------------------------------------"

# Join before/after by pod IP and report the delta per pod, then overall.
join -j 1 <(sort "${WORKDIR}/before") <(sort "${WORKDIR}/after") \
  | awk '
      {
        ip = $1; h0 = $2; q0 = $3; h1 = $4; q1 = $5
        dh = h1 - h0; dq = q1 - q0
        # A pod that restarted mid-run would show a negative delta; treat the
        # counter as reset rather than printing nonsense.
        if (dh < 0) dh = h1
        if (dq < 0) dq = q1
        TH += dh; TQ += dq
        printf "  %-16s queried %7d tokens   hit %7d   (%s)\n", ip, dq, dh,
               (dq > 0 ? sprintf("%.1f%%", 100 * dh / dq) : "n/a")
      }
      END {
        printf "  %-16s queried %7d tokens   hit %7d   (%s)\n", "TOTAL", TQ, TH,
               (TQ > 0 ? sprintf("%.1f%%", 100 * TH / TQ) : "n/a")
        if (TQ > 0) printf "\n  hit ratio: %.4f\n", TH / TQ
      }'

echo "=============================================================="
echo
echo "Grafana window for this run:"
echo "  from $(date -u -d @$(( START_EPOCH - 30 )) +%Y-%m-%dT%H:%M:%SZ) to $(date -u -d @$(( END_EPOCH + 60 )) +%Y-%m-%dT%H:%M:%SZ)"
