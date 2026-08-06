#!/usr/bin/env bash
# test-arachne-pump-lib.sh — offline unit tests for the shared pool helpers in
# scripts/arachne-pump-lib.sh (sourced by both run-parallel.sh and arachne-pump).
#
# Covers the F45.14.7 gap: the existing test-arachne-pump.sh always passes
# --no-health-gate, so the brcmfmac WiFi wedge detection (apl_network_unhealthy)
# and the live pool-cap rotation input (apl_read_cap) were never exercised. This
# harness feeds SYNTHETIC kernel-journal fixtures via a `journalctl` stub on PATH
# and a synthetic cap file — it never runs the real pool, launches a container,
# or touches the network.
#
# Run: ./scripts/test-arachne-pump-lib.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
LIB="$SCRIPT_DIR/arachne-pump-lib.sh"

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

# shellcheck source=scripts/arachne-pump-lib.sh
source "$LIB"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

# journalctl stub: emit the fixture in $STUB_JOURNAL for any kernel query, so
# apl_network_unhealthy greps a synthetic journal instead of the real one.
cat >| "$BIN/journalctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${STUB_JOURNAL:-}"
exit 0
EOF
chmod +x "$BIN/journalctl"

# Defaults the lib reads at call time.
HEALTH_GATE=1
HEALTH_WINDOW=120

# ── Health gate: each brcmfmac wedge signature trips it (returns 0 = unhealthy) ─
echo "--- health gate: wedge signature detection ---"
SIGNATURES=(
  "kernel: brcmfmac: brcmf_sdio_hdparse: Failed to alloc SKB"
  "kernel: brcmfmac: Firmware reported general error"
  "kernel: brcmfmac: Timeout on response for query command"
)
for sig in "${SIGNATURES[@]}"; do
  if PATH="$BIN:$PATH" STUB_JOURNAL="$sig" apl_network_unhealthy; then
    pass "unhealthy on signature: ${sig##*: }"
  else
    fail "expected unhealthy for signature: $sig"
  fi
done

# Mixed-case match (grep -iE) — a lowercased line still trips.
if PATH="$BIN:$PATH" STUB_JOURNAL="brcmfmac: timeout on response for query command" apl_network_unhealthy; then
  pass "case-insensitive match trips the gate"
else
  fail "case-insensitive match did not trip the gate"
fi

# ── Health gate: a quiet journal is healthy (returns 1) ────────────────────────
echo "--- health gate: quiet journal is healthy ---"
if PATH="$BIN:$PATH" STUB_JOURNAL="kernel: wlan0: link up, 866 Mbps" apl_network_unhealthy; then
  fail "benign journal should be healthy (returns 1)"
else
  pass "benign journal is healthy"
fi
if PATH="$BIN:$PATH" STUB_JOURNAL="" apl_network_unhealthy; then
  fail "empty journal should be healthy (returns 1)"
else
  pass "empty journal is healthy"
fi

# ── Health gate: disabled gate and missing journalctl degrade to healthy ───────
echo "--- health gate: graceful degradation ---"
if HEALTH_GATE=0 PATH="$BIN:$PATH" STUB_JOURNAL="brcmfmac: Failed to alloc SKB" apl_network_unhealthy; then
  fail "HEALTH_GATE=0 must report healthy even with a wedge in the journal"
else
  pass "HEALTH_GATE=0 short-circuits to healthy (running agents untouched)"
fi
# No journalctl on PATH → graceful healthy. The function returns 1 via the
# `command -v journalctl` guard (a builtin) before invoking any external command,
# so an empty bin dir on PATH exercises the real degradation path in-process.
EMPTY_BIN="$TMP/emptybin"; mkdir -p "$EMPTY_BIN"
if PATH="$EMPTY_BIN" STUB_JOURNAL="brcmfmac: Failed to alloc SKB" apl_network_unhealthy; then
  fail "missing journalctl should degrade to healthy (returns 1)"
else
  pass "missing journalctl degrades to healthy"
fi

# ── Pool cap: apl_read_cap is the live concurrency-cap input for rotation ──────
echo "--- pool cap: apl_read_cap (live rotation input) ---"
JOBS=6
CAP_FILE="$TMP/cap"

unset_cap() { rm -f "$CAP_FILE"; }

unset_cap
[[ "$(apl_read_cap)" == "6" ]] && pass "no cap file → JOBS default (6)" \
  || fail "no cap file expected 6 got '$(apl_read_cap)'"

printf '3\n' >| "$CAP_FILE"
[[ "$(apl_read_cap)" == "3" ]] && pass "cap file '3' → live retune to 3" \
  || fail "cap file '3' expected 3 got '$(apl_read_cap)'"

# Operator mid-run edit: drop the cap to 1.
printf '1' >| "$CAP_FILE"
[[ "$(apl_read_cap)" == "1" ]] && pass "cap file '1' → throttle to 1" \
  || fail "cap file '1' expected 1 got '$(apl_read_cap)'"

# Garbage / non-positive contents fall back to JOBS (never a 0/negative cap).
printf 'abc' >| "$CAP_FILE"
[[ "$(apl_read_cap)" == "6" ]] && pass "garbage cap file → falls back to JOBS (6)" \
  || fail "garbage cap file expected 6 got '$(apl_read_cap)'"
printf '0\n' >| "$CAP_FILE"
[[ "$(apl_read_cap)" == "6" ]] && pass "cap file '0' → rejected, falls back to JOBS (6)" \
  || fail "cap file '0' expected 6 got '$(apl_read_cap)'"

# ── Live-agent counting: the other rotation input (docker ps, stubbed) ─────────
echo "--- pool cap: apl_count_live_agents (docker ps stubbed) ---"
cat >| "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
# Answer `docker ps … --format {{.Names}}` from $STUB_NAMES (newline list).
if [[ "$1" == "ps" ]]; then printf '%s\n' "${STUB_NAMES:-}"; exit 0; fi
exit 0
EOF
chmod +x "$BIN/docker"

names=$'arachne-agent-feat-a\narachne-agent-feat-b'
got=$(DOCKER="$BIN/docker" STUB_NAMES="$names" apl_count_live_agents)
[[ "$got" == "2" ]] && pass "counts 2 live arachne-agent containers" \
  || fail "expected 2 live agents got '$got'"
got=$(DOCKER="$BIN/docker" STUB_NAMES="" apl_count_live_agents)
[[ "$got" == "0" ]] && pass "counts 0 when no agents are live" \
  || fail "expected 0 live agents got '$got'"
# Slug filter (rotation tops up a specific phase's pool).
got=$(DOCKER="$BIN/docker" STUB_NAMES="$names" apl_count_live_agents "feat-a")
[[ "$got" == "1" ]] && pass "slug filter counts only matching containers" \
  || fail "expected 1 filtered agent got '$got'"

# ── Host OAuth token freshness gate (access-token-only container model) ─────────
echo "--- host token gate: apl_host_token_stale ---"
CRED="$TMP/.credentials.json"
# expiresAt is epoch MILLISECONDS; pin "now" via ARACHNE_NOW_S for determinism.
NOW=1700000000
mk_cred() { printf '{"claudeAiOauth":{"accessToken":"a","expiresAt":%s}}' "$1" >| "$CRED"; }

# Fresh token (2h out, default 600s margin) → feed (0), silent.
mk_cred "$(( (NOW + 7200) * 1000 ))"
out=$(ARACHNE_NOW_S=$NOW apl_host_token_stale "$CRED"); rc=$?
{ [[ "$rc" -eq 0 && -z "$out" ]]; } && pass "fresh token → feed (silent)" \
  || fail "fresh token should feed silently; rc=$rc out='$out'"

# Within margin (5 min out, 600s margin) → pause (10) with reason.
mk_cred "$(( (NOW + 300) * 1000 ))"
out=$(ARACHNE_NOW_S=$NOW apl_host_token_stale "$CRED"); rc=$?
{ [[ "$rc" -eq 10 ]] && grep -q 'expires in 300s' <<<"$out"; } \
  && pass "near-expiry token → pause with countdown reason" \
  || fail "near-expiry should pause; rc=$rc out='$out'"

# Already expired → pause (10), reason names elapsed time.
mk_cred "$(( (NOW - 120) * 1000 ))"
out=$(ARACHNE_NOW_S=$NOW apl_host_token_stale "$CRED"); rc=$?
{ [[ "$rc" -eq 10 ]] && grep -q 'expired 120s ago' <<<"$out"; } \
  && pass "expired token → pause naming elapsed time" \
  || fail "expired should pause; rc=$rc out='$out'"

# Gate disabled → always feed (fail-open by config).
mk_cred "$(( (NOW - 120) * 1000 ))"
out=$(ARACHNE_TOKEN_GATE=0 ARACHNE_NOW_S=$NOW apl_host_token_stale "$CRED"); rc=$?
{ [[ "$rc" -eq 0 && -z "$out" ]]; } && pass "ARACHNE_TOKEN_GATE=0 → feed (disabled)" \
  || fail "disabled gate should feed; rc=$rc out='$out'"

# Missing file / unparseable expiresAt → feed (fail-open, never wedge the pump).
out=$(ARACHNE_NOW_S=$NOW apl_host_token_stale "$TMP/nope.json"); rc=$?
{ [[ "$rc" -eq 0 && -z "$out" ]]; } && pass "missing credentials file → feed (fail-open)" \
  || fail "missing file should feed; rc=$rc out='$out'"
printf '{"claudeAiOauth":{"accessToken":"a"}}' >| "$CRED"   # no expiresAt
out=$(ARACHNE_NOW_S=$NOW apl_host_token_stale "$CRED"); rc=$?
{ [[ "$rc" -eq 0 && -z "$out" ]]; } && pass "absent expiresAt → feed (fail-open)" \
  || fail "absent expiresAt should feed; rc=$rc out='$out'"

# Custom margin overrides default: 5 min out with a 900s margin → pause.
mk_cred "$(( (NOW + 300) * 1000 ))"
out=$(ARACHNE_NOW_S=$NOW apl_host_token_stale "$CRED" 900); rc=$?
[[ "$rc" -eq 10 ]] && pass "custom margin (900s) widens the pause window" \
  || fail "custom margin should pause; rc=$rc out='$out'"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]]
