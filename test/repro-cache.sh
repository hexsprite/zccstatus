#!/usr/bin/env bash
# Red-capable loop for the frozen cache countdown.
# Builds a transcript whose newest assistant turn is N minutes old, then asserts
# what the bar prints for it.
set -u
BIN="${BIN:-./zig-out/bin/zccstatus}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT

probe() { # minutes_ago  ttl_field  expected_substring
  local ago=$1 ttl=$2 want=$3
  local ts
  ts=$(python3 -c "
import datetime,sys
d=datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=$ago)
print(d.strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3]+'Z')")
  local other=ephemeral_5m_input_tokens
  [[ "$ttl" == "$other" ]] && other=ephemeral_1h_input_tokens
  cat > "$D/t.jsonl" <<JSONL
{"type":"assistant","timestamp":"$ts","message":{"usage":{"input_tokens":2,"cache_read_input_tokens":112150,"cache_creation_input_tokens":953,"cache_creation":{"$ttl":953,"$other":0}}}}
JSONL
  echo "{\"transcript_path\":\"$D/t.jsonl\",\"cwd\":\"$PWD\",\"model\":{\"id\":\"claude-opus-5[1m]\",\"display_name\":\"Opus 5\"}}" > "$D/p.json"
  local got
  got=$("$BIN" < "$D/p.json" | sed 's/\x1b\[[0-9;]*m//g')
  if [[ "$got" == *"$want"* ]]; then
    printf 'PASS  %4s min ago -> want %-6s | %s\n' "$ago" "$want" "$got"
  else
    printf 'FAIL  %4s min ago -> want %-6s | %s\n' "$ago" "$want" "$got"
    FAILED=1
  fi
}

FAILED=0
# 1h TTL: fresh, mid, warn, and long past expiry.
probe 0    ephemeral_1h_input_tokens "1h00m"
probe 30   ephemeral_1h_input_tokens "30m"
probe 57   ephemeral_1h_input_tokens "3m00s"
probe 360  ephemeral_1h_input_tokens "cold"
# 5m TTL
probe 1    ephemeral_5m_input_tokens "4m00s"
probe 600  ephemeral_5m_input_tokens "cold"

# --- model label, against a real captured payload -------------------------
real() {
  local want=$1 notwant=$2
  local got
  got=$("$BIN" < test/fixtures/real-payload.json | sed 's/\x1b\[[0-9;]*m//g')
  if [[ "$got" == *"$want"* && "$got" != *"$notwant"* ]]; then
    printf 'PASS  real payload -> %s\n' "$got"
  else
    printf 'FAIL  real payload: want %s, not %s | %s\n' "$want" "$notwant" "$got"
    FAILED=1
  fi
}
real "Opus 5 (1M)" "context"
exit $FAILED
