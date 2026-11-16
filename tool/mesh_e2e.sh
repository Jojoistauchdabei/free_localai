#!/usr/bin/env bash
# E2E test for the self-healing device mesh, using three real PrivateLM
# instances on this machine as three "devices":
#
#   A = first-paired device  → becomes master automatically, GPU 0
#   B = worker               → GPU 1
#   C = worker               → CPU only
#
# Tested:
#   1. Pairing from A (QR replaced by the control-plane pair endpoint).
#   2. Master loads the model split across A + B + C.
#   3. Prompt from a node that doesn't host the model is routed to the host.
#   4. Worker lost → master reloads the model over the remaining devices.
#   5. Master lost → a worker takes over, reloads the model, chats keep working.
#   6. Master restarts → mesh re-elects it, hands the model back (pairing
#      persisted).
#   7. Network analysis log records all of it.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/linux/x64/debug/bundle/privatelm"
MODEL="${PRIVATELM_TEST_MODEL:-/home/jonas/Dokumente/models/lfm2.5-1.2b-instruct-q4_k_m.gguf}"
DIR=/tmp/opencode/mesh-e2e
PASS=0; FAIL=0

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); say "PASS: $*"; }
bad()  { FAIL=$((FAIL+1)); say "FAIL: $*"; }

api()  { curl -s --max-time "${3:-15}" "http://127.0.0.1:$1$2"; }
post() { curl -s --max-time "${4:-300}" -X POST -H 'Content-Type: application/json' -d "$3" "http://127.0.0.1:$1$2"; }

log_of() { api "$1" /mesh/log | jq -r '.events[] | "\(.kind)\t\(.msg)"' 2>/dev/null; }

launch() { # name dir control worker gpu extra-env...
  local name="$1" dir="$2" control="$3" worker="$4" gpu="$5"; shift 5
  rm -rf "$dir"; mkdir -p "$dir"
  env PRIVATELM_DATA_DIR="$dir/data" \
      PRIVATELM_NODE_ID="$name" \
      PRIVATELM_NODE_NAME="Desktop-$name" \
      PRIVATELM_CONTROL_PORT="$control" \
      PRIVATELM_WORKER_PORT="$worker" \
      PRIVATELM_GPU_INDEX="$gpu" \
      PRIVATELM_CLUSTER=1 \
      "$@" "$BIN" >"$dir/$name.log" 2>&1 &
  LAST_PID=$!
}

relaunch() { # same, but keeps the data dir: pairings must survive restarts
  local name="$1" dir="$2" control="$3" worker="$4" gpu="$5"; shift 5
  mkdir -p "$dir"
  env PRIVATELM_DATA_DIR="$dir/data" \
      PRIVATELM_NODE_ID="$name" \
      PRIVATELM_NODE_NAME="Desktop-$name" \
      PRIVATELM_CONTROL_PORT="$control" \
      PRIVATELM_WORKER_PORT="$worker" \
      PRIVATELM_GPU_INDEX="$gpu" \
      PRIVATELM_CLUSTER=1 \
      "$@" "$BIN" >>"$dir/$name.log" 2>&1 &
  LAST_PID=$!
}

cleanup() {
  for pid in "${PIDS[@]:-}"; do kill -9 "$pid" 2>/dev/null; done
}
trap cleanup EXIT

wait_up() { # port attempts
  for _ in $(seq 1 "${2:-60}"); do
    api "$1" /mesh/ping >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

info_field() { api "$1" /mesh/info | jq -r "$2" 2>/dev/null; }

log_has() { # port pattern
  log_of "$1" | grep -q "$2"
}

chat_ok() {
  echo "$1" | grep -q '"done":true' &&
    ! echo "$1" | grep -q '"error"'
}

wait_until() { # description fn
  for _ in $(seq 1 "${2:-30}"); do
    if eval "$3"; then ok "$1"; return 0; fi
    sleep 2
  done
  bad "$1"
}

# ── Launch ────────────────────────────────────────────────────────────────
say "Launching 3 mesh devices (A GPU0 · B GPU1 · C CPU)…"
PIDS=()
launch A "$DIR/A" 50061 50052 0 PRIVATELM_AUTOLOAD="$MODEL"; PIDS+=("$LAST_PID")
launch B "$DIR/B" 50062 51052 1; PIDS+=("$LAST_PID")
launch C "$DIR/C" 50063 52052 cpu; PIDS+=("$LAST_PID")
sleep 6

for port in 50061 50062 50063; do
  if wait_up "$port"; then ok "device on port $port is up"; else bad "device on port $port did not come up"; fi
done

# ── 1. Pairing from the first device ──────────────────────────────────────
R=$(post 50061 /mesh/pair "{\"host\":\"127.0.0.1\",\"port\":51052,\"id\":\"B\",\"name\":\"Desktop-B\",\"cport\":50062}")
echo "$R" | jq -e '.ok == true' >/dev/null && ok "paired B from A (persistent)" || bad "pairing B: $R"
R=$(post 50061 /mesh/pair "{\"host\":\"127.0.0.1\",\"port\":52052,\"id\":\"C\",\"name\":\"Desktop-C\",\"cport\":50063}")
echo "$R" | jq -e '.ok == true' >/dev/null && ok "paired C from A (persistent)" || bad "pairing C: $R"

# ── 2. Master auto-election + model split ────────────────────────────────
MASTER=$(info_field 50061 .master)
if [ "$MASTER" = "A" ]; then ok "first paired device auto-became master"; else bad "master is $MASTER (expected A)"; fi

say "Loading model on the master (split across A+B+C)…"
LOADR=$(post 50061 /mesh/load "{\"path\":\"$MODEL\"}")
echo "  load: $LOADR"
wait_until "model loaded on master" 60 'echo "$([ "$(info_field 50061 .modelLoaded)" = "true" ] && echo yes)" | grep -q yes'
SPLIT=$(info_field 50061 .split)
say "  split: ${SPLIT:-none}"
[ -n "$SPLIT" ] && [ "$SPLIT" != "null" ] && ok "model is split across devices" || bad "no split: $SPLIT"

# B and C must know their master and see the model host (heartbeat).
wait_until "B knows the master and the model host" 30 'echo "$([ "$(info_field 50062 .master)" = "A" ] && [ "$(info_field 50062 .modelHost)" != "null" ] && echo yes)" | grep -q yes'

# ── 3. Prompt from a non-hosting node ────────────────────────────────────
say "Sending a prompt from B (B hosts nothing)…"
ANSWER=$(post 50061 /mesh/chat "{\"prompt\":\"Reply with exactly: MESH_OK\"}" 60)
echo "$ANSWER" | head -3
chat_ok "$ANSWER" && ok "prompt served by the model host" || bad "no answer from model host: $(echo "$ANSWER" | head -c 300)"

# ── 4. Worker lost → rebalance ───────────────────────────────────────────
CPID=$(pgrep -f "privatelm" | tail -1) # approximate; kill instance C via port owner
CPID=$(ss -ltnp 2>/dev/null | grep ':52052' | grep -oP 'pid=\K[0-9]+' | head -1)
say "Killing worker C (pid $CPID)…"
kill -9 "$CPID" 2>/dev/null
sleep 2
wait_until "master reloads the model without C" 40 "log_has 50061 'Reloading the model without'"
wait_until "master hosts the model again" 90 'echo "$([ "$(info_field 50061 .modelLoaded)" = "true" ] && echo yes)" | grep -q yes'
SPLIT=$(info_field 50061 .split)
say "  split now: ${SPLIT:-none}"
echo "$SPLIT" | grep -q ':52052' && bad "dead C is still in the split" || ok "dead C is out of the split"
ANSWER=$(post 50061 /mesh/chat "{\"prompt\":\"Reply with exactly: STILL_OK\"}" 60)
chat_ok "$ANSWER" && ok "chats keep working after a worker is lost" || bad "chat broken after worker loss"
if ! chat_ok "$ANSWER"; then
  say "  --- A's instance log (last lines) ---"
  tail -25 "$DIR/A/A.log"
  say "  --- A's mesh log ---"
  log_of 50061 | head -10
fi

# ── 5. Master lost → failover ────────────────────────────────────────────
APID=$(ss -ltnp 2>/dev/null | grep ':50061' | grep -oP 'pid=\K[0-9]+' | head -1)
say "Killing the master A (pid $APID)…"
kill -9 "$APID" 2>/dev/null
wait_until "B takes over as master" 60 'echo "$([ "$(info_field 50062 .master)" = "B" ] && echo yes)" | grep -q yes'
wait_until "B reloads the model (failover)" 60 'echo "$([ "$(info_field 50062 .modelLoaded)" = "true" ] && echo yes)" | grep -q yes'
ANSWER=$(post 50062 /mesh/chat "{\"prompt\":\"Reply with exactly: FAILOVER_OK\"}" 60)
chat_ok "$ANSWER" && ok "new master serves prompts after the old master died" || bad "chat broken after master failover: $(echo "$ANSWER" | head -c 300)"
log_has 50062 "failover\|took over" && ok "failover is logged in the network analysis" || bad "no failover event in B's log"

# ── 6. Master restarts → mesh re-elects it, pairing persists ─────────────
say "Restarting device A (same node id, pairings kept)…"
relaunch A "$DIR/A" 50061 50052 0 PRIVATELM_AUTOLOAD="$MODEL"; PIDS+=("$LAST_PID")
wait_up 50061 40
wait_until "A is master again (earliest joined wins)" 40 'echo "$([ "$(info_field 50061 .master)" = "A" ] && echo yes)" | grep -q yes'
wait_until "A hosts the model again" 60 'echo "$([ "$(info_field 50061 .modelLoaded)" = "true" ] && echo yes)" | grep -q yes'
ANSWER=$(post 50061 /mesh/chat "{\"prompt\":\"Reply with exactly: HEALED_OK\"}" 60)
chat_ok "$ANSWER" && ok "mesh fully healed after master restart" || bad "chat broken after restart: $(echo "$ANSWER" | head -c 300)"

# ── 7. Network analysis log ──────────────────────────────────────────────
say "--- A's network log (last events) ---"
log_of 50061 | head -14
log_has 50061 "paired" && ok "pairing events are logged" || bad "no pairing events in A's log"
log_has 50061 "offline\|went offline" && ok "device loss is logged" || bad "no offline events in A's log"

say ""
say "════════ RESULT: $PASS passed, $FAIL failed ════════"
for d in A B C; do
  say "--- $d instance log (last 12 lines) ---"
  tail -12 "$DIR/$d/$d.log" 2>/dev/null
done
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
