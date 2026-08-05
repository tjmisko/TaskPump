#!/usr/bin/env bash
# test-arachne-monitor.sh — fixture-driven tests for scripts/arachne-monitor.
#
# Covers the pure-rendering surfaces: the --demo bars (cell math + critical
# fill), the usage_bars path driven by a stubbed arachne-usage, the --log redraw
# instrumentation, the cached disk gauge (abbreviated sizes), the refresh
# interval, gauge alignment, the run-scoped notes field, the two-column top
# layout (notes side-by-side / stacked), and the height-clipped scroll viewport.
# docker is stubbed (no containers) so no real daemon is touched. Geometry is
# pinned via ARACHNE_MONITOR_COLS / _LINES so layout is deterministic.
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
# Disk gauge runs du/git/df on the real tree — disable it for the generic tests;
# the dedicated disk test (Test 8) re-enables it against stubs + a seeded cache.
export ARACHNE_MONITOR_DISK=0

# ── Test 1: --demo renders both window bars with the toolbar glyphs ────────────
echo "--- Test 1: demo bars render ---"
out=$("$CLI" --demo 2>/dev/null)
grep -q '5h' <<<"$out" && grep -q '7d' <<<"$out" && pass "demo shows 5h and 7d labels" || fail "demo missing window labels"
grep -q '▐' <<<"$out" && grep -q '▌' <<<"$out" && pass "demo bars have ▐ ▌ end-caps" || fail "demo missing end-caps"
grep -q '█' <<<"$out" && grep -q '░' <<<"$out" && pass "demo bars use █ filled / ░ empty cells" || fail "demo missing bar glyphs"

# ── Test 2: bar cell math + critical fill (driven via the usage stub) ─────────
echo "--- Test 2: bar cell math + critical fill ---"
make_usage_stub 95 62        # 5h=95% (critical/red), 7d=62% (normal/terracotta)
out2=$("$CLI" 2>/dev/null)
five_line=$(grep '5h' <<<"$out2" | head -1)
filled=$(grep -o '█' <<<"$five_line" | wc -l | tr -d ' ')
[[ "$filled" == "19" ]] && pass "95% bar has 19/20 filled cells" || fail "95% expected 19 filled got $filled"
empties=$(grep -o '░' <<<"$five_line" | wc -l | tr -d ' ')
[[ "$empties" == "1" ]] && pass "95% bar has 1/20 empty cell" || fail "95% expected 1 empty got $empties"
printf '%s' "$five_line" | grep -q $'\033\[1;31m' && pass "95% (critical) bar uses red fill" || fail "95% bar not red"
seven_line=$(grep '7d' <<<"$out2" | head -1)
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

# ── Test 6: --watch logs redraws; the cached paint is cheap ───────────────────
echo "--- Test 6: watch redraw cadence + cost ---"
LOGB="$TMP/watch.log"
timeout 3 "$CLI" --watch 1 --log "$LOGB" >/dev/null 2>&1 </dev/null || true
grep -q 'mode=batched' "$LOGB" 2>/dev/null && pass "watch logs a redraw line" || fail "no redraw logged: $(cat "$LOGB" 2>/dev/null)"
# Compute is read-from-cache + one usage fetch, so it must stay cheap (the whole
# point of the background-cache rework: the slow scans never run on the paint).
cm=$(grep -oE 'compute_ms=[0-9]+' "$LOGB" | head -1 | grep -oE '[0-9]+')
[[ "${cm:-9999}" -le 500 ]] && pass "cached paint compute is cheap (${cm}ms ≤ 500)" || fail "compute too slow: ${cm}ms"

# ── Test 7: unknown arg is rejected ───────────────────────────────────────────
echo "--- Test 7: arg handling ---"
"$CLI" --bogus >/dev/null 2>&1; rc=$?
[[ "$rc" -ne 0 ]] && pass "unknown arg exits non-zero" || fail "unknown arg accepted"
"$CLI" --help >/dev/null 2>&1 && pass "--help exits 0" || fail "--help failed"

# ── Test 8: disk gauge (stubbed df + seeded cache, no real du/git) ────────────
echo "--- Test 8: disk gauge ---"
# df stub: 100G total; available comes from $DF_AVAIL_KB so colour bands can be
# exercised. Field layout matches `df -Pk` (avail is field 4).
cat >| "$BIN/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted-on"
echo "/dev/stub 104857600 $((104857600 - ${DF_AVAIL_KB:-52428800})) ${DF_AVAIL_KB:-52428800} 50% /"
EOF
chmod +x "$BIN/df"
# Seed the heavy-sizing cache so disk_refresh_if_stale never shells out to du/git.
DCACHE="$TMP/disk.tsv"
cat >| "$DCACHE" <<'EOF'
MAIN	490000000
DKR	Images	15.4GB	7.9GB (51%)
DKR	Build Cache	9.6GB	1.7GB
WT	feat/big	12000000000
WT	feat/small	300000000
WT	feat/tiny	30000000
EOF
FAKE_MAIN="$TMP/fakerepo"; mkdir -p "$FAKE_MAIN"
run_disk() { ARACHNE_MONITOR_DISK=1 ARACHNE_MONITOR_DISK_CACHE="$DCACHE" \
  ARACHNE_MONITOR_DISK_TTL=99999 ARACHNE_MONITOR_MAIN_ROOT="$FAKE_MAIN" "$CLI" 2>/dev/null; }

strip_ansi() { sed -r 's/\x1b\[[0-9;]*m//g'; }   # text assertions ignore colour
out=$(DF_AVAIL_KB=52428800 run_disk)   # 50G free
outp=$(strip_ansi <<<"$out")
grep -qE '^[[:space:]]*Disk ' <<<"$outp" && pass "disk gauge renders a Disk line" || fail "no Disk line:\n$outp"
grep -qE '50(\.0)?G free / 100(\.0)?G' <<<"$outp" && pass "free/total shown (50G/100G)" || fail "free/total missing:\n$outp"
grep -qE 'worktrees 11\.[0-9]G in 3' <<<"$outp" && pass "worktrees total+count (3 dirs)" || fail "worktree total wrong:\n$outp"
grep -qE 'main 467\.[0-9]M' <<<"$outp" && pass "main footprint shown" || fail "main missing:\n$outp"
# docker sizes abbreviated to the human_bytes style (15.4GB → 15.4G).
grep -qE 'docker img 15\.4G · cache 9\.6G' <<<"$outp" && pass "docker breakdown abbreviated (15.4G/9.6G)" || fail "docker line wrong:\n$outp"
# The largest-worktrees line was removed (compact, btop-ish).
grep -q 'largest:' <<<"$outp" && fail "largest: line should be gone" || pass "largest: line removed"

# Free-space colour bands (panic<5G red, pause<10G amber, else terracotta).
fb() { DF_AVAIL_KB=$1 run_disk | grep -E '^[[:space:]]*Disk '; }
printf '%s' "$(fb 52428800)" | grep -q $'\033\[38;5;173m' && pass "50G free → terracotta bar" || fail "50G not terracotta"
printf '%s' "$(fb 8388608)"  | grep -q $'\033\[33m'      && pass "8G free → amber (pause band)"  || fail "8G not amber"
printf '%s' "$(fb 3145728)"  | grep -q $'\033\[1;31m'    && pass "3G free → red (panic band)"    || fail "3G not red"

# --no-disk suppresses the gauge entirely.
nd=$(ARACHNE_MONITOR_DISK=1 ARACHNE_MONITOR_DISK_CACHE="$DCACHE" ARACHNE_MONITOR_MAIN_ROOT="$FAKE_MAIN" "$CLI" --no-disk 2>/dev/null)
grep -qE '^[[:space:]]*Disk ' <<<"$nd" && fail "--no-disk still drew the gauge" || pass "--no-disk suppresses the gauge"

# ── Test 9: refresh interval — default 1s, env var, positional precedence ──────
echo "--- Test 9: refresh interval (#155) ---"
make_usage_stub 30 40
LOGI="$TMP/interval.log"
# Default: --watch with no number logs interval=1.
timeout 2 "$CLI" --watch --log "$LOGI" >/dev/null 2>&1 </dev/null || true
grep -qE 'interval=1s ' "$LOGI" 2>/dev/null && pass "default --watch interval is 1s" || fail "default interval not 1s: $(head -1 "$LOGI" 2>/dev/null)"
# Env var sets the interval.
LOGE="$TMP/interval-env.log"
ARACHNE_MONITOR_INTERVAL=3 timeout 2 "$CLI" --watch --log "$LOGE" >/dev/null 2>&1 </dev/null || true
grep -qE 'interval=3s ' "$LOGE" 2>/dev/null && pass "ARACHNE_MONITOR_INTERVAL=3 honoured" || fail "env interval not 3s: $(head -1 "$LOGE" 2>/dev/null)"
# Positional arg wins over the env var.
LOGP="$TMP/interval-pos.log"
ARACHNE_MONITOR_INTERVAL=3 timeout 2 "$CLI" --watch 5 --log "$LOGP" >/dev/null 2>&1 </dev/null || true
grep -qE 'interval=5s ' "$LOGP" 2>/dev/null && pass "positional --watch 5 beats env var" || fail "positional did not win: $(head -1 "$LOGP" 2>/dev/null)"

# ── Test 10: gauge alignment — 5h / 7d / Disk bars start at the same column ─────
echo "--- Test 10: gauge alignment ---"
make_usage_stub 42 73
align_out=$(ARACHNE_MONITOR_DISK=1 ARACHNE_MONITOR_DISK_CACHE="$DCACHE" \
  ARACHNE_MONITOR_DISK_TTL=99999 ARACHNE_MONITOR_MAIN_ROOT="$FAKE_MAIN" \
  ARACHNE_MONITOR_COLS=200 DF_AVAIL_KB=52428800 "$CLI" 2>/dev/null | strip_ansi)
bar_col() { awk -v lbl="$1" '$0 ~ ("^[[:space:]]*" lbl " ") { print index($0, "▐"); exit }' <<<"$align_out"; }
c5=$(bar_col "5h"); c7=$(bar_col "7d"); cd=$(bar_col "Disk")
[[ -n "$c5" && "$c5" == "$c7" && "$c5" == "$cd" ]] \
  && pass "5h/7d/Disk bars align at the same column ($c5)" \
  || fail "bars misaligned: 5h=$c5 7d=$c7 Disk=$cd"

# ── Test 11: notes panel — header, seeded lines, empty hint (stacked layout) ───
echo "--- Test 11: notes field ---"
# Narrow width → the notes column stacks UNDER the left column at column 0, so
# header/line anchors are deterministic. (Side-by-side is exercised in Test 14.)
NF="$TMP/notes.md"
printf -- '- 09:00  first note\n- 09:05  second note\n' >| "$NF"
nout=$(env ARACHNE_MONITOR_COLS=60 ARACHNE_MONITOR_NOTES_FILE="$NF" "$CLI" 2>/dev/null | strip_ansi)
grep -qE '^Notes \[' <<<"$nout" && pass "notes panel renders a header" || fail "no Notes header:\n$nout"
grep -q 'first note'  <<<"$nout" && grep -q 'second note' <<<"$nout" && pass "notes panel shows seeded lines" || fail "seeded notes missing:\n$nout"
grep -q '(n · C-g)' <<<"$nout" && pass "notes header lists the edit keys" || fail "edit-key hint missing:\n$nout"
EF="$TMP/empty-notes.md"; : >| "$EF"
eout=$(env ARACHNE_MONITOR_COLS=60 ARACHNE_MONITOR_NOTES_FILE="$EF" "$CLI" 2>/dev/null | strip_ansi)
grep -q 'no notes yet' <<<"$eout" && pass "empty notes file shows the add hint" || fail "empty-notes hint missing:\n$eout"
# Notes tail is bounded by NOTES_TAIL.
printf -- '- a\n- b\n- c\n- d\n- e\n- f\n' >| "$NF"
tout=$(env ARACHNE_MONITOR_COLS=60 ARACHNE_MONITOR_NOTES_FILE="$NF" ARACHNE_MONITOR_NOTES_TAIL=2 "$CLI" 2>/dev/null | strip_ansi)
shown=$(grep -cE '^- [a-f]$' <<<"$tout")
[[ "$shown" == "2" ]] && pass "notes panel honours NOTES_TAIL=2" || fail "expected 2 tail lines got $shown:\n$tout"

# ── Test 12: notes run-key — scoped to the pump phases + start time ────────────
echo "--- Test 12: notes scoped to the pump run ---"
PSTATE="$TMP/pump.state"
printf '%s' '{"phases":"F43..F63","started_at":"2026-06-23T20:36:23Z","status":"running","open_tasks":28,"ceiling":95}' >| "$PSTATE"
ndir="$TMP/notesdir"
key_out=$(ARACHNE_PUMP_STATE_FILE="$PSTATE" ARACHNE_MONITOR_NOTES_DIR="$ndir" "$CLI" 2>/dev/null | strip_ansi)
grep -q 'Notes \[F43..F63\]' <<<"$key_out" && pass "notes header shows the pump phase-range" || fail "phase-range label missing:\n$key_out"

# ── Test 13: docker-size abbreviation (21.26GB → 21.3G, 0B stays 0B) ───────────
echo "--- Test 13: docker size formatting ---"
DC13="$TMP/disk13.tsv"
printf 'MAIN\t100000000\nDKR\tImages\t21.26GB\t0B\nDKR\tContainers\t4.396GB\t0B\nDKR\tLocal Volumes\t0B\t0B\nDKR\tBuild Cache\t11.33GB\t0B\n' >| "$DC13"
d13=$(ARACHNE_MONITOR_DISK=1 ARACHNE_MONITOR_DISK_CACHE="$DC13" ARACHNE_MONITOR_DISK_TTL=99999 \
  ARACHNE_MONITOR_MAIN_ROOT="$FAKE_MAIN" DF_AVAIL_KB=52428800 "$CLI" 2>/dev/null | strip_ansi)
grep -qE 'img 21\.3G · cont 4\.4G · vol 0B · cache 11\.3G' <<<"$d13" \
  && pass "docker sizes abbreviated (21.3G/4.4G/0B/11.3G)" || fail "docker abbrev wrong:\n$(grep -i worktrees <<<"$d13")"

# ── Test 14: two-column top — notes side-by-side when wide, stacked when narrow ─
echo "--- Test 14: two-column layout ---"
make_usage_stub 40 50
NF14="$TMP/notes14.md"; printf -- '- 12:00  a note here\n' >| "$NF14"
wide=$(env ARACHNE_MONITOR_COLS=200 ARACHNE_MONITOR_NOTES_FILE="$NF14" "$CLI" 2>/dev/null | strip_ansi)
# Side-by-side: the Notes header sits in the right column (indented), not at col 0.
grep -qE '^ +Notes \[' <<<"$wide" && pass "wide terminal puts Notes beside the gauges" || fail "notes not side-by-side:\n$wide"
narrow=$(env ARACHNE_MONITOR_COLS=60 ARACHNE_MONITOR_NOTES_FILE="$NF14" "$CLI" 2>/dev/null | strip_ansi)
# Stacked: Notes header is on its own line at column 0.
grep -qE '^Notes \[' <<<"$narrow" && pass "narrow terminal stacks Notes below" || fail "notes not stacked:\n$narrow"

# ── Test 15: watch frame is clipped to the terminal height ─────────────────────
echo "--- Test 15: height-clipped viewport ---"
# In --watch the frame must never exceed $LINES rows (so the top never scrolls
# away). Capture one paint, isolate the last cursor-home frame, count its rows.
CAP="$TMP/clip.cap"
ARACHNE_MONITOR_LINES=12 ARACHNE_MONITOR_COLS=120 timeout 2 "$CLI" --watch 1 >| "$CAP" 2>/dev/null </dev/null || true
# Split on ESC[H (cursor home); take the last full frame; strip CSI; count lines.
frame=$(awk 'BEGIN{RS="\033\\[H"} {last=$0} END{printf "%s", last}' "$CAP" | sed -r 's/\x1b\[[0-9;?]*[A-Za-z]//g')
rows=$(printf '%s' "$frame" | grep -c .)
[[ -n "$rows" && "$rows" -le 12 ]] && pass "watch frame clipped to height (${rows} ≤ 12 rows)" || fail "frame not clipped: ${rows} rows"

# ── Test 16: tab bar + --tab selection ────────────────────────────────────────
echo "--- Test 16: tabs ---"
make_usage_stub 30 40
sess_out=$("$CLI" 2>/dev/null | strip_ansi)
grep -q '┤ SESSIONS ├' <<<"$sess_out" && pass "SESSIONS tab is active by default" || fail "no active SESSIONS tab:\n$sess_out"
grep -q 'GRAPH' <<<"$sess_out" && pass "GRAPH tab is listed" || fail "GRAPH tab missing"
graph_out=$("$CLI" --tab graph 2>/dev/null | strip_ansi)
grep -q '┤ GRAPH ├' <<<"$graph_out" && pass "--tab graph activates the GRAPH tab" || fail "--tab graph not active:\n$graph_out"
grep -q '✓ done' <<<"$graph_out" && pass "GRAPH tab shows the status legend" || fail "no legend on the graph tab"
# No pump state is configured in this harness, so the graph must say so rather
# than rendering the entire ledger.
grep -q 'no pump running' <<<"$graph_out" && pass "graph tab degrades cleanly with no pump" || fail "no-pump fallback missing:\n$graph_out"
"$CLI" --tab bogus >/dev/null 2>&1 && fail "--tab accepted a bogus value" || pass "--tab rejects a bogus value"

# ── Test 17: two feed lines per session (regression: dropped final line) ──────
echo "--- Test 17: two transcript lines per session ---"
FAKE_ROOT="$TMP/fakeroot"; mkdir -p "$FAKE_ROOT/.worktrees/feat/x"
LOGF="$FAKE_ROOT/.worktrees/feat/x/.arachne-agent.log"
printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"text":"first event line"}]}}' \
  '{"type":"assistant","message":{"content":[{"text":"second event line"}]}}' >| "$LOGF"
cat >| "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    '{{.Names}}|{{.State}}|{{.Status}}') echo 'arachne-agent-feat-x|running|Up 3 minutes'; exit 0 ;;
    '{{.Names}}') echo 'arachne-agent-feat-x'; exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$BIN/docker"
FEED_CACHE="$TMP/feed-sess.tsv"
run_feed() { ARACHNE_MONITOR_REPO_ROOT="$FAKE_ROOT" ARACHNE_MONITOR_SESS_CACHE="$FEED_CACHE" \
             ARACHNE_MONITOR_COLS=120 "$CLI" 2>/dev/null | strip_ansi; }
run_feed >/dev/null; sleep 2; feed_out=$(run_feed)     # first call warms the background cache
grep -q 'first event line'  <<<"$feed_out" && pass "first feed line rendered"  || fail "first feed line missing:\n$feed_out"
grep -q 'second event line' <<<"$feed_out" && pass "second feed line rendered (TAIL_LINES=2)" || fail "second feed line dropped:\n$feed_out"
# docker stub back to "no containers" for anything that follows.
printf '#!/usr/bin/env bash\nexit 0\n' >| "$BIN/docker"; chmod +x "$BIN/docker"

# ── Test 18: GRAPH tab cursor ────────────────────────────────────────────────
# --moves replays cursor keys in one-shot mode, which is what makes navigation
# assertable without a pty — the same trick --tab plays for the graph itself.
echo "--- Test 18: graph cursor ---"
GTD="$TMP/gtasks"; mkdir -p "$GTD"
gtask() {  # <id> <status> <claimed_by> [blocker ...]
    local id="$1" st="$2" by="$3"; shift 3
    {
        echo '---'; echo "id: \"$id\""; echo 'phase: "F96"'; echo "status: $st"
        echo "claimed_by: $by"; echo "turn_budget_remaining: 7"
        echo "goal: \"drive the $id outcome home\""
        if (( $# )); then echo 'blockers:'; for b in "$@"; do echo "  - \"$b\""; done
        else echo 'blockers: []'; fi
        echo '---'; echo body
    } >| "$GTD/$id.md"
}
#   .1 ─┬─ .2 ─── .4 ─── .6      (.6 also blocked by .1: a 3-layer span)
#       └─ .3 ─── .5
gtask F96.1 done        ""
gtask F96.2 done        ""        F96.1
gtask F96.3 done        ""        F96.1
gtask F96.4 in_progress feat/f96  F96.2
gtask F96.5 open        ""        F96.3
gtask F96.6 open        ""        F96.4 F96.1
GPS="$TMP/graph-pump.state"
printf '%s' '{"phases":"F96","started_at":"2026-08-05T09:00:00Z","status":"running"}' >| "$GPS"
gmon() { ARACHNE_PUMP_STATE_FILE="$GPS" ARACHNE_TASKS_DIR="$GTD" ARACHNE_MONITOR_COLS=100 \
             "$CLI" --tab graph "$@" 2>/dev/null | strip_ansi; }
gsel() { gmon "$@" | awk '/^F96\./ { print $1; exit }'; }

sel=$(gsel)
[[ "$sel" == "F96.4" ]] && pass "cursor defaults to the in_progress task ($sel)" \
    || fail "default cursor should be the live task, got '$sel'"
gmon | grep -q 'drive the F96.4 outcome home' \
    && pass "status bar shows the selected task's goal" || fail "goal missing from the status bar"
gmon | grep -qE 'F96\.4 .*7 turns.*feat/f96.*blockers F96\.2✓' \
    && pass "status bar shows turns, branch and blocker statuses" \
    || fail "status bar detail missing:\n$(gmon | sed -n '5p')"
gmon | grep -q '┃ \.4 ' && pass "the selection is drawn with a heavy border" || fail "no heavy border in the graph"

# ↑ prefers a blocker over the merely-nearest node; ↓ prefers a dependent.
sel=$(gsel --cursor F96.4 --moves k)
[[ "$sel" == "F96.2" ]] && pass "↑ walks to a blocker ($sel)" || fail "↑ should reach F96.2, got '$sel'"
sel=$(gsel --cursor F96.2 --moves j)
[[ "$sel" == "F96.4" ]] && pass "↓ walks to a dependent ($sel)" || fail "↓ should reach F96.4, got '$sel'"

# Horizontal movement stays inside the layer.
sel=$(gsel --cursor F96.2 --moves l)
[[ "$sel" == "F96.3" ]] && pass "→ moves within the layer ($sel)" || fail "→ should reach F96.3, got '$sel'"
sel=$(gsel --cursor F96.2 --moves hhhh)
[[ "$sel" == "F96.2" ]] && pass "← clamps at the start of the layer" || fail "← ran off the layer to '$sel'"
sel=$(gsel --cursor F96.2 --moves llll)
[[ "$sel" == "F96.3" ]] && pass "→ clamps at the end of the layer" || fail "→ ran off the layer to '$sel'"

# g / G jump to the ends of the DAG.
sel=$(gsel --cursor F96.5 --moves g)
[[ "$sel" == "F96.1" ]] && pass "g jumps to the first layer ($sel)" || fail "g should reach F96.1, got '$sel'"
sel=$(gsel --cursor F96.1 --moves G)
[[ "$sel" == "F96.6" ]] && pass "G jumps to the last layer ($sel)" || fail "G should reach F96.6, got '$sel'"

# An unknown cursor falls back rather than rendering a selectionless graph.
sel=$(gsel --cursor F96.999)
[[ "$sel" == "F96.4" ]] && pass "an unknown cursor id falls back to the default" || fail "stale cursor kept: '$sel'"

# The viewport follows the selection: in a terminal narrower than the graph, the
# selected node must be on screen.
narrow() { ARACHNE_PUMP_STATE_FILE="$GPS" ARACHNE_TASKS_DIR="$GTD" ARACHNE_MONITOR_COLS=40 \
               "$CLI" --tab graph --cursor "$1" 2>/dev/null | strip_ansi; }
narrow F96.5 | grep -q '┃ \.5 ' && pass "viewport pans to keep the selection visible" \
    || fail "selection off-screen in a narrow terminal:\n$(narrow F96.5)"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
