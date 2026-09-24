#!/usr/bin/env bash
#
# Does the router still know where the caches are after it restarts?
#
#   ~/bench/restart-test.sh [trials]
#
# THE ONE THING THE APPROXIMATE PRODUCER STRUCTURALLY CANNOT DO
#   The approximate producer builds its index from its OWN past routing
#   decisions, and that index lives only in EPP memory. Restart the EPP and it
#   is gone -- the router has to relearn from live traffic, and until it does it
#   is guessing.
#
#   The precise producer subscribes to the model servers' ZMQ events and, on
#   startup, replays buffered events from each pod's replay socket (5559). The
#   servers still hold the blocks; the router asks them what they have.
#
#   So: warm a distinct prefix onto whichever pod the router picks, restart ONLY
#   the EPP -- never the simulators, whose caches must survive -- and send the
#   same prefix again. Did it land back on a pod that still holds the blocks?
#
# WHY THIS IS THE RIGHT TEST AND THE BENCHMARK IS NOT
#   It is CATEGORICAL. The hit ratio comparison is a couple of points against a
#   harness whose latency and distribution vary by more than that between
#   identical runs (see bench/README.md, "The repeat"). This asks a yes/no
#   question per trial and counts, so noise shows up as a count rather than
#   hiding inside an average.
#
#   With three prefill pods, a router that knows nothing still lands correctly
#   about 1 trial in 3 by luck. That is the null hypothesis, and it is why this
#   runs several trials rather than one.
#
# WHAT TO EXPECT
#   approximate  ~1/3 of trials retain cache after the restart (chance)
#   precise      close to all of them
#
# READ THE SCORE, NOT ANY SINGLE TRIAL.
#
set -euo pipefail

TRIALS="${1:-6}"
NS=llm-d
GW="${GW:-http://192.168.58.11}"
MODEL="Qwen/Qwen2.5-1.5B-Instruct"

# Each trial needs its own prefix, long enough to span whole 64-token blocks --
# a prefix shorter than the block size cannot be cached at all, which is the
# mistake bench run 1 made. ~120 words puts this comfortably over 2 blocks.
filler() {
  local seed="$1" i out=""
  for i in $(seq 1 120); do
    out+="topic${seed}word${i} "
  done
  printf '%s' "$out"
}

# Ask the gateway for a completion and print the cached-token count the server
# reports back. That number -- not a log line, not a metric -- is the evidence
# that this prompt hit a warm cache.
cached_tokens() {
  local prompt="$1"
  curl -s --max-time 30 "${GW}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"${prompt}\"}],\"max_tokens\":4}" \
    | grep -o '"cached_tokens":[0-9]*' | head -1 | cut -d: -f2
}

echo "=============================================================="
echo " EPP RESTART TEST -- ${TRIALS} trials"
echo "--------------------------------------------------------------"
echo " Which producer is bound:"
kubectl -n "$NS" logs deploy/sim-pool-epp 2>/dev/null \
  | grep -oE '"(precise|approx)-prefix-cache-producer/[a-z-]+"' | sort -u | sed 's/^/   /' || true
echo "=============================================================="

# Clear the simulators ONCE, before anything. They are never restarted again:
# the whole test depends on the servers keeping their blocks across the EPP
# restart. Restarting them here would destroy the thing being measured.
echo "-- clearing model server caches (once, and only here)"
kubectl -n "$NS" rollout restart deploy/sim-prefill deploy/sim-decode >/dev/null
kubectl -n "$NS" rollout status deploy/sim-prefill --timeout=300s >/dev/null
kubectl -n "$NS" rollout status deploy/sim-decode  --timeout=300s >/dev/null
sleep 15

declare -a PROMPTS
echo "-- phase 1: warming ${TRIALS} distinct prefixes"
for t in $(seq 1 "$TRIALS"); do
  P="$(filler "$t")"
  PROMPTS[$t]="$P"
  cold=$(cached_tokens "$P")
  warm=$(cached_tokens "$P")     # second send: should now be cached somewhere
  printf "   trial %d: cold=%s  warm=%s\n" "$t" "${cold:-?}" "${warm:-?}"
done

echo "-- restarting ONLY the EPP (simulator caches stay warm)"
kubectl -n "$NS" rollout restart deploy/sim-pool-epp >/dev/null
kubectl -n "$NS" rollout status deploy/sim-pool-epp --timeout=180s >/dev/null
# Give the precise producer a moment to replay from each pod's 5559 socket.
sleep 10

echo "-- phase 2: same prefixes, first request after the restart"
RETAINED=0
for t in $(seq 1 "$TRIALS"); do
  after=$(cached_tokens "${PROMPTS[$t]}")
  if [ "${after:-0}" -gt 0 ] 2>/dev/null; then
    RETAINED=$((RETAINED+1)); verdict="RETAINED"
  else
    verdict="lost"
  fi
  printf "   trial %d: cached_tokens=%-6s %s\n" "$t" "${after:-0}" "$verdict"
done

echo "=============================================================="
echo " RETAINED ${RETAINED} / ${TRIALS} after the EPP restart"
echo
echo "   ~1/3 is what a router that knows nothing scores by chance,"
echo "   with three candidate pods. Close to ${TRIALS}/${TRIALS} means the"
echo "   index survived the restart."
echo "=============================================================="
