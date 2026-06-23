#!/usr/bin/env bash
# test-arachne-monitor.sh — fixture-driven tests for scripts/arachne-monitor.
#
# Covers the pure-rendering surfaces added for the usage bars + flicker-free
# repaint + redraw instrumentation: the --demo bars (cell math + critical fill),
# the usage_bars path driven by a stubbed arachne-usage, and the --log redraw
# instrumentation. docker is stubbed (no containers) so no real daemon is touched.
#
# Run: ./scripts/test-arachne-monitor.sh  (exits non-zero on any failure)
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
CLI="$SCRIPT_DIR/arachne-monitor"
PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

# docker stub: no containers, regardless of args.
cat >| "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN/docker"
export PATH="$BIN:$PATH"

# arachne-usage stub: --json emits a fixed payload with the two window bars; any
# other mode is a no-op. Percentages chosen to be unambiguous in the output.
make_usage_stub() {  # $1 = five% $2 = seven%
  cat >| "$BIN/arachne-usage" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  --json) printf '%s' '{"bind_percent":$2,"reset_at":"2026-06-24T04:00:00+00:00","windows":[{"label":"5h","percent":$1,"reset_at":"2026-06-23T21:00:00+00:00"},{"label":"7d","percent":$2,"reset_at":"2026-06-24T04:00:00+00:00"}]}' ;;
  --percent) echo "$2" ;;
  *) : ;;
esac
EOF
  chmod +x "$BIN/arachne-usage"
}
# unreachable-meter stub: --json emits the empty-windows shape.
make_usage_stub_unreachable() {
  cat >| "$BIN/arachne-usage" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --json) printf '%s' '{"bind_percent":null,"windows":[],"severity":"unknown"}' ;;
  *) : ;;
esac
EOF
  chmod +x "$BIN/arachne-usage"
}
export ARACHNE_USAGE="$BIN/arachne-usage"
# Point everything that would read real state at empty/nonexistent paths so the
# no-pump (usage_bars fallback) branch runs hermetically.
export ARACHNE_PUMP_STATE_FILE="$TMP/no-such-pump.state"
export MANIFEST="$TMP/empty-manifest.tsv"; : >| "$MANIFEST"

# ── Test 1: --demo renders both window bars with the toolbar glyphs ────────────
echo "--- Test 1: demo bars render ---"
out=$("$CLI" --demo 2>/dev/null)
grep -q '5h' <<<"$out" && grep -q '7d' <<<"$out" && pass "demo shows 5h and 7d labels" || fail "demo missing window labels"
grep -q '▐' <<<"$out" && grep -q '▌' <<<"$out" && pass "demo bars have ▐ ▌ end-caps" || fail "demo missing end-caps"
grep -q '█' <<<"$out" && grep -q '░' <<<"$out" && pass "demo bars use █ filled / ░ empty cells" || fail "demo missing bar glyphs"

# ── Test 2: bar cell math — 95% → 19 filled cells, critical (red) fill ─────────
echo "--- Test 2: bar cell math + critical fill ---"
five_line=$(grep '5h' <<<"$out" | head -1)
filled=$(grep -o '█' <<<"$five_line" | wc -l | tr -d ' ')
[[ "$filled" == "19" ]] && pass "95% bar has 19/20 filled cells" || fail "95% expected 19 filled got $filled"
empties=$(grep -o '░' <<<"$five_line" | wc -l | tr -d ' ')
[[ "$empties" == "1" ]] && pass "95% bar has 1/20 empty cell" || fail "95% expected 1 empty got $empties"
printf '%s' "$five_line" | grep -q $'\033\[1;31m' && pass "95% (critical) bar uses red fill" || fail "95% bar not red"
seven_line=$(grep '7d' <<<"$out" | head -1)
printf '%s' "$seven_line" | grep -q $'\033\[38;5;173m' && pass "62% (normal) bar uses terracotta fill" || fail "62% bar not terracotta"

# ── Test 3: usage_bars path (no pump) reflects the stubbed percentages ─────────
echo "--- Test 3: live usage_bars path ---"
make_usage_stub 42 73
out=$("$CLI" 2>/dev/null)
grep -q ' 42%' <<<"$out" && pass "5h bar shows stubbed 42%" || fail "5h 42% missing:\n$out"
grep -q ' 73%' <<<"$out" && pass "7d bar shows stubbed 73%" || fail "7d 73% missing:\n$out"
fc=$(grep '5h' <<<"$out" | grep -o '█' | wc -l | tr -d ' ')
[[ "$fc" == "8" ]] && pass "42% bar has 8/20 filled cells (42/5)" || fail "42% expected 8 filled got $fc"

# ── Test 4: meter unreachable → no bars, snapshot still renders ────────────────
echo "--- Test 4: unreachable meter degrades gracefully ---"
make_usage_stub_unreachable
out=$("$CLI" 2>/dev/null)
grep -q '▐' <<<"$out" && fail "drew a bar with no window data" || pass "no bar drawn when meter unreachable"
grep -q 'no arachne-agent containers' <<<"$out" && pass "snapshot body still renders" || fail "snapshot body missing"

# ── Test 5: --log instruments each redraw (one-shot) ──────────────────────────
echo "--- Test 5: redraw logging (one-shot) ---"
make_usage_stub 30 40
LOG="$TMP/redraw.log"
"$CLI" --log "$LOG" >/dev/null 2>&1
[[ -s "$LOG" ]] && pass "--log wrote a redraw entry" || fail "--log produced no entry"
grep -qE 'redraw=1 .*compute_ms=[0-9]+ .*paint_ms=[0-9]+ .*lines=[0-9]+ .*bytes=[0-9]+' "$LOG" \
  && pass "redraw line has compute_ms/paint_ms/lines/bytes" || fail "redraw line malformed: $(cat "$LOG")"

# ── Test 6: --watch batched vs --legacy-paint distinguished in the log ────────
echo "--- Test 6: watch redraw modes ---"
LOGB="$TMP/watch-batched.log"; LOGL="$TMP/watch-legacy.log"
timeout 3 "$CLI" --watch 1 --log "$LOGB" >/dev/null 2>&1 || true
timeout 3 "$CLI" --watch 1 --legacy-paint --log "$LOGL" >/dev/null 2>&1 || true
grep -q 'mode=batched' "$LOGB" 2>/dev/null && pass "batched watch logs mode=batched" || fail "batched mode not logged: $(cat "$LOGB" 2>/dev/null)"
grep -q 'mode=legacy'  "$LOGL" 2>/dev/null && pass "legacy watch logs mode=legacy"  || fail "legacy mode not logged: $(cat "$LOGL" 2>/dev/null)"
# In batched mode the on-screen paint is near-instant (compute happens off-screen);
# in legacy mode the render-to-cleared-screen time is the flicker window.
if grep -q 'mode=batched' "$LOGB" 2>/dev/null; then
  bp=$(grep -oE 'paint_ms=[0-9]+' "$LOGB" | head -1 | grep -oE '[0-9]+')
  [[ "${bp:-99}" -le 30 ]] && pass "batched paint_ms is small (${bp}ms — no blank-screen flicker)" || fail "batched paint_ms unexpectedly high: ${bp}ms"
fi

# ── Test 7: unknown arg is rejected ───────────────────────────────────────────
echo "--- Test 7: arg handling ---"
"$CLI" --bogus >/dev/null 2>&1; rc=$?
[[ "$rc" -ne 0 ]] && pass "unknown arg exits non-zero" || fail "unknown arg accepted"
"$CLI" --help >/dev/null 2>&1 && pass "--help exits 0" || fail "--help failed"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
