#!/usr/bin/env bash
# test-arachne-usage.sh — fixture-driven tests for scripts/arachne-usage.
#
# The live HTTP path is smoke-tested manually (`arachne-usage --percent` vs the
# ~/.claude/claude-status toolbar). Here we drive the PARSER hermetically by
# seeding the cache file and pinning TTL high so no network call is ever made.
#
# Run: ./scripts/test-arachne-usage.sh  (exits non-zero on any failure)
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
CLI="$SCRIPT_DIR/arachne-usage"
PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
CACHE="$TMP/usage.json"
RESET_FILE="$TMP/reset"
# Pin TTL high so a seeded cache is always "fresh"; point creds at a nonexistent
# file so even a fetch attempt (fail-open test) makes no network call.
export ARACHNE_USAGE_CACHE="$CACHE"
export ARACHNE_USAGE_TTL=999999
export ARACHNE_USAGE_RESET_FILE="$RESET_FILE"
export ARACHNE_CREDENTIALS="$TMP/no-such-credentials.json"

seed() { printf '%s' "$1" >| "$CACHE"; }
unseed() { rm -f "$CACHE"; }

FUTURE=$(( $(date +%s) + 7200 ))
PAST=$(( $(date +%s) - 7200 ))

# ── The confirmed 2026-06-22 sample: 77% session / 21% weekly, Opus null ──────
SAMPLE77='{
  "five_hour":  {"utilization":77,"resets_at":"2026-06-22T21:00:00+00:00"},
  "seven_day":  {"utilization":21,"resets_at":"2026-06-24T04:00:00+00:00"},
  "seven_day_opus": null,
  "seven_day_sonnet": {"utilization":2,"resets_at":"2026-06-24T04:00:00+00:00"},
  "limits": [
    {"kind":"session","group":"session","percent":77,"severity":"warning","is_active":true},
    {"kind":"weekly_all","group":"weekly","percent":21,"severity":"normal","is_active":false},
    {"kind":"weekly_scoped","group":"weekly","percent":2,"severity":"normal","is_active":false,"scope":{"model":{"display_name":"Sonnet"}}}
  ]
}'

echo "--- Test 1: parse the 77% sample ---"
seed "$SAMPLE77"
got=$("$CLI" --percent)
[[ "$got" == "77" ]] && pass "--percent = 77 (binding window)" || fail "--percent expected 77 got '$got'"
js=$("$CLI" --json)
[[ "$(jq -r '.bind_percent' <<<"$js")" == "77" ]] && pass "--json bind_percent=77" || fail "json bind_percent: $js"
[[ "$(jq -r '.five_hour' <<<"$js")" == "77" ]] && pass "--json five_hour=77" || fail "json five_hour: $js"
[[ "$(jq -r '.seven_day' <<<"$js")" == "21" ]] && pass "--json seven_day=21" || fail "json seven_day: $js"
[[ "$(jq -r '.severity' <<<"$js")" == "normal" ]] && pass "--json severity=normal (77<80)" || fail "json severity: $js"
[[ "$(jq -r '.reset_epoch' <<<"$js")" =~ ^[0-9]+$ ]] && pass "--json reset_epoch is an epoch" || fail "json reset_epoch: $js"
# windows[] feeds the monitor's per-window bars: exactly 5h + binding 7d.
[[ "$(jq -r '.windows | length' <<<"$js")" == "2" ]] && pass "--json windows has 2 entries" || fail "json windows length: $js"
[[ "$(jq -r '.windows[0] | "\(.label):\(.percent)"' <<<"$js")" == "5h:77" ]] && pass "--json windows[5h]=77" || fail "json windows 5h: $js"
[[ "$(jq -r '.windows[1] | "\(.label):\(.percent)"' <<<"$js")" == "7d:21" ]] && pass "--json windows[7d]=21 (seven_day, Opus null)" || fail "json windows 7d: $js"
[[ "$(jq -r '.windows[1].reset_at' <<<"$js")" == "2026-06-24T04:00:00+00:00" ]] && pass "--json windows[7d] carries seven_day reset" || fail "json 7d reset: $js"
[[ "$(jq -r '.five_hour_reset_at' <<<"$js")" == "2026-06-22T21:00:00+00:00" ]] && pass "--json five_hour_reset_at present" || fail "json 5h reset: $js"

echo "--- Test 2: gate below ceiling feeds ---"
"$CLI" --gate --ceiling 95 2>/dev/null; rc=$?
[[ "$rc" -eq 0 ]] && pass "--gate --ceiling 95 exits 0 at 77%" || fail "gate@77/95 exit expected 0 got $rc"
"$CLI" --gate --ceiling 70 2>/dev/null; rc=$?
[[ "$rc" -eq 10 ]] && pass "--gate --ceiling 70 exits 10 at 77%" || fail "gate@77/70 exit expected 10 got $rc"

echo "--- Test 3: synthetic 96% trips the 95 ceiling ---"
seed "${SAMPLE77/\"utilization\":77/\"utilization\":96}"
got=$("$CLI" --percent)
[[ "$got" == "96" ]] && pass "--percent = 96" || fail "--percent expected 96 got '$got'"
"$CLI" --gate --ceiling 95 2>/dev/null; rc=$?
[[ "$rc" -eq 10 ]] && pass "--gate --ceiling 95 exits 10 at 96%" || fail "gate@96/95 exit expected 10 got $rc"
[[ "$(jq -r '.severity' <<<"$("$CLI" --json)")" == "critical" ]] && pass "severity=critical at 96%" || fail "severity not critical at 96"

echo "--- Test 4: Opus weekly cap is included in bind_percent ---"
seed '{"five_hour":{"utilization":10,"resets_at":"2026-06-22T21:00:00+00:00"},
       "seven_day":{"utilization":10,"resets_at":"2026-06-24T04:00:00+00:00"},
       "seven_day_opus":{"utilization":97,"resets_at":"2026-06-25T00:00:00+00:00"},
       "limits":[]}'
got=$("$CLI" --percent)
[[ "$got" == "97" ]] && pass "Opus weekly 97% binds over 5h/7d 10%" || fail "opus-bind expected 97 got '$got'"
wj=$("$CLI" --json)
[[ "$(jq -r '.windows[1] | "\(.percent)"' <<<"$wj")" == "97" ]] && pass "windows[7d]=97 (Opus weekly binds the 7d bar)" || fail "7d window not Opus: $wj"
[[ "$(jq -r '.windows[1].reset_at' <<<"$wj")" == "2026-06-25T00:00:00+00:00" ]] && pass "windows[7d] carries the Opus weekly reset" || fail "7d reset not Opus: $wj"

echo "--- Test 5: Sonnet-scoped cap does NOT gate an Opus run ---"
seed '{"five_hour":{"utilization":12,"resets_at":"2026-06-22T21:00:00+00:00"},
       "seven_day":{"utilization":12,"resets_at":"2026-06-24T04:00:00+00:00"},
       "seven_day_opus":null,
       "limits":[{"kind":"weekly_scoped","percent":99,"scope":{"model":{"display_name":"Sonnet"}}}]}'
got=$("$CLI" --percent)
[[ "$got" == "12" ]] && pass "Sonnet 99% excluded; bind=12 (named windows)" || fail "sonnet-exclude expected 12 got '$got'"

echo "--- Test 6: limits[] fallback when named windows are null (excludes Sonnet) ---"
seed '{"five_hour":{"resets_at":"2026-06-22T21:00:00+00:00"},
       "seven_day":{},"seven_day_opus":null,
       "limits":[{"kind":"session","percent":50,"resets_at":"2026-06-22T21:00:00+00:00"},
                 {"kind":"weekly_scoped","percent":99,"scope":{"model":{"display_name":"Sonnet"}}}]}'
got=$("$CLI" --percent)
[[ "$got" == "50" ]] && pass "fallback to limits[] max excluding Sonnet = 50" || fail "fallback expected 50 got '$got'"

echo "--- Test 7: fail-open when meter unreachable ---"
unseed   # no cache + nonexistent creds → no usable payload, no network
got=$("$CLI" --percent)
[[ "$got" == "unknown" ]] && pass "--percent = unknown when meter unreachable" || fail "unreachable --percent expected 'unknown' got '$got'"
"$CLI" --gate --ceiling 95 2>/dev/null; rc=$?
[[ "$rc" -eq 0 ]] && pass "--gate fails OPEN (exit 0) when meter unreachable" || fail "fail-open gate expected 0 got $rc"

echo "--- Test 8: reset backstop hard-pauses regardless of low usage ---"
seed "$SAMPLE77"   # 77%, well under ceiling
printf '%s\n' "$FUTURE" >| "$RESET_FILE"
"$CLI" --gate --ceiling 95 2>/dev/null; rc=$?
[[ "$rc" -eq 10 ]] && pass "--gate exits 10 inside reset-backstop window (despite 77%)" || fail "backstop gate expected 10 got $rc"
printf '%s\n' "$PAST" >| "$RESET_FILE"
"$CLI" --gate --ceiling 95 2>/dev/null; rc=$?
[[ "$rc" -eq 0 ]] && pass "--gate ignores an expired backstop (exit 0)" || fail "expired-backstop gate expected 0 got $rc"
rm -f "$RESET_FILE"

echo "--- Test 9: --scan-logs extracts a reset epoch to the backstop file ---"
LOG="$TMP/agent.log"
printf 'some line\nClaude AI usage limit reached|%s\nmore\n' "$FUTURE" >| "$LOG"
"$CLI" --scan-logs "$LOG" 2>/dev/null
got=$(tr -dc '0-9' < "$RESET_FILE" 2>/dev/null || echo "")
[[ "$got" == "$FUTURE" ]] && pass "--scan-logs wrote pipe-epoch ($FUTURE)" || fail "scan-logs pipe-epoch expected $FUTURE got '$got'"
rm -f "$RESET_FILE"
ISO="2026-06-22T21:00:00+00:00"; ISO_EPOCH=$(date -d "$ISO" +%s)
if [[ "$ISO_EPOCH" -gt "$(date +%s)" ]]; then
  printf 'result: 5-hour limit reached, resets at %s\n' "$ISO" >| "$LOG"
  "$CLI" --scan-logs "$LOG" 2>/dev/null
  got=$(tr -dc '0-9' < "$RESET_FILE" 2>/dev/null || echo "")
  [[ "$got" == "$ISO_EPOCH" ]] && pass "--scan-logs wrote ISO reset ($ISO_EPOCH)" || fail "scan-logs ISO expected $ISO_EPOCH got '$got'"
else
  pass "--scan-logs ISO case skipped (fixture ISO in the past)"
fi

echo "--- Test 10: no token ever appears in output ---"
seed "$SAMPLE77"
out=$("$CLI" --json; "$CLI" --percent)
printf '%s' "$out" | grep -qiE 'bearer|accessToken|sk-ant' && fail "secret-shaped text leaked into output" || pass "no secret-shaped text in output"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
