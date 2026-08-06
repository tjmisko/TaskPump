#!/usr/bin/env bash
# test-arachne-monitor.sh — fixture-driven tests for scripts/arachne-monitor.
#
# Covers the pure-rendering surfaces: the --demo bars (cell math + critical
# fill), the usage_bars path driven by a stubbed arachne-usage, the --log redraw
# instrumentation, the cached disk gauge (abbreviated sizes), the refresh
# interval, gauge alignment, the run-scoped notes field, the two-column top
# layout (notes side-by-side / stacked), and the height-clipped scroll viewport.
# docker is stubbed (no containers) so no real daemon is touched. Geometry is
# pinned via TASKPUMP_MONITOR_COLS / _LINES so layout is deterministic.
#
# Run: ./scripts/test-arachne-monitor.sh  (exits non-zero on any failure)
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CLI="$TP_ROOT/libexec/tp-monitor"
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
export TASKPUMP_USAGE="$BIN/arachne-usage"
# Point everything that would read real state at empty/nonexistent paths so the
# no-pump (usage_bars fallback) branch runs hermetically.
export TASKPUMP_PUMP_STATE_FILE="$TMP/no-such-pump.state"
export TASKPUMP_MANIFEST="$TMP/empty-manifest.tsv"; : >| "${TASKPUMP_MANIFEST}"
# Disk gauge runs du/git/df on the real tree — disable it for the generic tests;
# the dedicated disk test (Test 8) re-enables it against stubs + a seeded cache.
export TASKPUMP_MONITOR_DISK=0
# EVERY cache the monitor keeps — sessions, pump queue, disk, and the GRAPH tab's
# node index — lives at "$TMPDIR/arachne-monitor-*.<cksum of repo root>.tsv". The
# key is the repo root, not this harness, so without isolation the fixtures read
# whatever a real monitor run left behind: a stubbed "no containers" docker would
# assert against the host's actual agents, and an F96 cursor fixture would
# navigate a cached F79 graph. Both produced failures that depended on whether a
# pump happened to be running. Redirecting TMPDIR into the per-run temp dir
# isolates all four at once.
export TMPDIR="$TMP"
export TASKPUMP_MONITOR_SESS_CACHE="$TMP/generic-sess.tsv"
"$CLI" >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$TASKPUMP_MONITOR_SESS_CACHE" ]] && break; sleep 0.3; done

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
printf '%s' "$five_line" | grep -q $'\033\[0;1;38;5;203m' \
  && pass "95% (critical) bar uses the alert coral" || fail "95% bar not coral"
seven_line=$(grep '7d' <<<"$out2" | head -1)
printf '%s' "$seven_line" | grep -q $'\033\[0;38;5;173m' \
  && pass "62% (normal) bar uses terracotta fill" || fail "62% bar not terracotta"

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
run_disk() { TASKPUMP_MONITOR_DISK=1 TASKPUMP_MONITOR_DISK_CACHE="$DCACHE" \
  TASKPUMP_MONITOR_DISK_TTL=99999 TASKPUMP_MONITOR_MAIN_ROOT="$FAKE_MAIN" "$CLI" 2>/dev/null; }

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
# Matches "Disk" alone, not "Disk ": these assertions read the RAW output (they
# are about escapes), and the label is now wrapped in its own colour, so the
# line is `<indent>ESC[…mDiskESC[0m …` with no space adjacent to the word.
fb() { DF_AVAIL_KB=$1 run_disk | grep 'Disk'; }
# The escalation bands reuse STATE's amber and coral verbatim, so amber means
# "attention" and coral means "act now" for a disk exactly as for a task.
printf '%s' "$(fb 52428800)" | grep -q $'\033\[0;38;5;173m'   && pass "50G free → terracotta bar" || fail "50G not terracotta"
printf '%s' "$(fb 8388608)"  | grep -q $'\033\[0;38;5;179m'   && pass "8G free → amber (pause band)"  || fail "8G not amber"
printf '%s' "$(fb 3145728)"  | grep -q $'\033\[0;1;38;5;203m' && pass "3G free → coral (panic band)"  || fail "3G not coral"

# --no-disk suppresses the gauge entirely.
nd=$(TASKPUMP_MONITOR_DISK=1 TASKPUMP_MONITOR_DISK_CACHE="$DCACHE" TASKPUMP_MONITOR_MAIN_ROOT="$FAKE_MAIN" "$CLI" --no-disk 2>/dev/null)
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
TASKPUMP_MONITOR_INTERVAL=3 timeout 2 "$CLI" --watch --log "$LOGE" >/dev/null 2>&1 </dev/null || true
grep -qE 'interval=3s ' "$LOGE" 2>/dev/null && pass "TASKPUMP_MONITOR_INTERVAL=3 honoured" || fail "env interval not 3s: $(head -1 "$LOGE" 2>/dev/null)"
# Positional arg wins over the env var.
LOGP="$TMP/interval-pos.log"
TASKPUMP_MONITOR_INTERVAL=3 timeout 2 "$CLI" --watch 5 --log "$LOGP" >/dev/null 2>&1 </dev/null || true
grep -qE 'interval=5s ' "$LOGP" 2>/dev/null && pass "positional --watch 5 beats env var" || fail "positional did not win: $(head -1 "$LOGP" 2>/dev/null)"

# ── Test 10: gauge alignment — 5h / 7d / Disk bars start at the same column ─────
echo "--- Test 10: gauge alignment ---"
make_usage_stub 42 73
align_out=$(TASKPUMP_MONITOR_DISK=1 TASKPUMP_MONITOR_DISK_CACHE="$DCACHE" \
  TASKPUMP_MONITOR_DISK_TTL=99999 TASKPUMP_MONITOR_MAIN_ROOT="$FAKE_MAIN" \
  TASKPUMP_MONITOR_COLS=200 DF_AVAIL_KB=52428800 "$CLI" 2>/dev/null | strip_ansi)
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
nout=$(env TASKPUMP_MONITOR_COLS=60 TASKPUMP_MONITOR_NOTES_FILE="$NF" "$CLI" 2>/dev/null | strip_ansi)
grep -qE '^Notes \[' <<<"$nout" && pass "notes panel renders a header" || fail "no Notes header:\n$nout"
grep -q 'first note'  <<<"$nout" && grep -q 'second note' <<<"$nout" && pass "notes panel shows seeded lines" || fail "seeded notes missing:\n$nout"
grep -q '(n · C-g)' <<<"$nout" && pass "notes header lists the edit keys" || fail "edit-key hint missing:\n$nout"
EF="$TMP/empty-notes.md"; : >| "$EF"
eout=$(env TASKPUMP_MONITOR_COLS=60 TASKPUMP_MONITOR_NOTES_FILE="$EF" "$CLI" 2>/dev/null | strip_ansi)
grep -q 'no notes yet' <<<"$eout" && pass "empty notes file shows the add hint" || fail "empty-notes hint missing:\n$eout"
# Notes tail is bounded by NOTES_TAIL.
printf -- '- a\n- b\n- c\n- d\n- e\n- f\n' >| "$NF"
tout=$(env TASKPUMP_MONITOR_COLS=60 TASKPUMP_MONITOR_NOTES_FILE="$NF" TASKPUMP_MONITOR_NOTES_TAIL=2 "$CLI" 2>/dev/null | strip_ansi)
shown=$(grep -cE '^- [a-f]$' <<<"$tout")
[[ "$shown" == "2" ]] && pass "notes panel honours NOTES_TAIL=2" || fail "expected 2 tail lines got $shown:\n$tout"

# ── Test 12: notes run-key — scoped to the pump phases + start time ────────────
echo "--- Test 12: notes scoped to the pump run ---"
PSTATE="$TMP/pump.state"
printf '%s' '{"phases":"F43..F63","started_at":"2026-06-23T20:36:23Z","status":"running","open_tasks":28,"ceiling":95}' >| "$PSTATE"
ndir="$TMP/notesdir"
key_out=$(TASKPUMP_PUMP_STATE_FILE="$PSTATE" TASKPUMP_MONITOR_NOTES_DIR="$ndir" "$CLI" 2>/dev/null | strip_ansi)
grep -q 'Notes \[F43..F63\]' <<<"$key_out" && pass "notes header shows the pump phase-range" || fail "phase-range label missing:\n$key_out"

# ── Test 13: docker-size abbreviation (21.26GB → 21.3G, 0B stays 0B) ───────────
echo "--- Test 13: docker size formatting ---"
DC13="$TMP/disk13.tsv"
printf 'MAIN\t100000000\nDKR\tImages\t21.26GB\t0B\nDKR\tContainers\t4.396GB\t0B\nDKR\tLocal Volumes\t0B\t0B\nDKR\tBuild Cache\t11.33GB\t0B\n' >| "$DC13"
d13=$(TASKPUMP_MONITOR_DISK=1 TASKPUMP_MONITOR_DISK_CACHE="$DC13" TASKPUMP_MONITOR_DISK_TTL=99999 \
  TASKPUMP_MONITOR_MAIN_ROOT="$FAKE_MAIN" DF_AVAIL_KB=52428800 "$CLI" 2>/dev/null | strip_ansi)
grep -qE 'img 21\.3G · cont 4\.4G · vol 0B · cache 11\.3G' <<<"$d13" \
  && pass "docker sizes abbreviated (21.3G/4.4G/0B/11.3G)" || fail "docker abbrev wrong:\n$(grep -i worktrees <<<"$d13")"

# ── Test 14: two-column top — notes side-by-side when wide, stacked when narrow ─
echo "--- Test 14: two-column layout ---"
make_usage_stub 40 50
NF14="$TMP/notes14.md"; printf -- '- 12:00  a note here\n' >| "$NF14"
wide=$(env TASKPUMP_MONITOR_COLS=200 TASKPUMP_MONITOR_NOTES_FILE="$NF14" "$CLI" 2>/dev/null | strip_ansi)
# Side-by-side: the Notes header sits in the right column (indented), not at col 0.
grep -qE '^ +Notes \[' <<<"$wide" && pass "wide terminal puts Notes beside the gauges" || fail "notes not side-by-side:\n$wide"
narrow=$(env TASKPUMP_MONITOR_COLS=60 TASKPUMP_MONITOR_NOTES_FILE="$NF14" "$CLI" 2>/dev/null | strip_ansi)
# Stacked: Notes header is on its own line at column 0.
grep -qE '^Notes \[' <<<"$narrow" && pass "narrow terminal stacks Notes below" || fail "notes not stacked:\n$narrow"

# ── Test 15: watch frame is clipped to the terminal height ─────────────────────
echo "--- Test 15: height-clipped viewport ---"
# In --watch the frame must never exceed $LINES rows (so the top never scrolls
# away). Capture one paint, isolate the last cursor-home frame, count its rows.
CAP="$TMP/clip.cap"
TASKPUMP_MONITOR_LINES=12 TASKPUMP_MONITOR_COLS=120 timeout 2 "$CLI" --watch 1 >| "$CAP" 2>/dev/null </dev/null || true
# Split on ESC[H (cursor home); take the last full frame; strip CSI; count lines.
frame=$(awk 'BEGIN{RS="\033\\[H"} {last=$0} END{printf "%s", last}' "$CAP" | sed -r 's/\x1b\[[0-9;?]*[A-Za-z]//g')
rows=$(printf '%s' "$frame" | grep -c .)
[[ -n "$rows" && "$rows" -le 12 ]] && pass "watch frame clipped to height (${rows} ≤ 12 rows)" || fail "frame not clipped: ${rows} rows"

# ── Test 16: tab bar + --tab selection ────────────────────────────────────────
echo "--- Test 16: tabs ---"
make_usage_stub 30 40
# The active tab is marked by WEIGHT now, not by `┤ ├`, so it can only be
# asserted before strip_ansi. tab_row picks the one line carrying both labels.
tab_row() { grep 'SESSIONS.*GRAPH'; }
C_STRONG_SGR=$'\033[0;1;38;5;252m'   # the `1` is the active-tab mark
sess_raw=$("$CLI" 2>/dev/null); sess_out=$(strip_ansi <<<"$sess_raw")
sess_tab=$(tab_row <<<"$sess_raw")
grep -qF "$C_STRONG_SGR  SESSIONS" <<<"$sess_tab" && pass "SESSIONS tab is active by default" || fail "no active SESSIONS tab:\n$(cat -v <<<"$sess_tab")"
grep -q 'GRAPH' <<<"$sess_out" && pass "GRAPH tab is listed" || fail "GRAPH tab missing"
graph_raw=$("$CLI" --tab graph 2>/dev/null); graph_out=$(strip_ansi <<<"$graph_raw")
graph_tab=$(tab_row <<<"$graph_raw")
grep -qF "$C_STRONG_SGR  GRAPH" <<<"$graph_tab" && pass "--tab graph activates the GRAPH tab" || fail "--tab graph not active:\n$(cat -v <<<"$graph_tab")"
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
run_feed() { TASKPUMP_MONITOR_REPO_ROOT="$FAKE_ROOT" TASKPUMP_MONITOR_SESS_CACHE="$FEED_CACHE" \
             TASKPUMP_MONITOR_COLS=120 "$CLI" 2>/dev/null | strip_ansi; }
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
gmon() { TASKPUMP_PUMP_STATE_FILE="$GPS" TASKPUMP_TASKS_DIR="$GTD" TASKPUMP_MONITOR_COLS=100 \
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
gmon | grep -q '┃ F96.4 ' && pass "the selection is drawn with a heavy border" || fail "no heavy border in the graph"

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

# gg / G jump to the ends of the DAG, as in vim.
sel=$(gsel --cursor F96.5 --moves gg)
[[ "$sel" == "F96.1" ]] && pass "gg jumps to the first layer ($sel)" || fail "gg should reach F96.1, got '$sel'"
# A lone g is a prefix, not a motion — it must not move anything on its own.
sel=$(gsel --cursor F96.5 --moves g)
[[ "$sel" == "F96.5" ]] && pass "a lone g is an incomplete motion" || fail "bare g moved the cursor to '$sel'"
# ...and a key after it cancels the prefix rather than being swallowed by it.
sel=$(gsel --cursor F96.2 --moves gl)
[[ "$sel" == "F96.3" ]] && pass "a key after g cancels the prefix and still acts" \
    || fail "g swallowed the following key, got '$sel'"

# ^ / $ work along the LAYER — the graph's horizontal axis.
sel=$(gsel --cursor F96.3 --moves '^')
[[ "$sel" == "F96.2" ]] && pass "^ jumps to the first node in the layer ($sel)" \
    || fail "^ should reach F96.2, got '$sel'"
sel=$(gsel --cursor F96.2 --moves '$')
[[ "$sel" == "F96.3" ]] && pass "\$ jumps to the last node in the layer ($sel)" \
    || fail "\$ should reach F96.3, got '$sel'"
sel=$(gsel --cursor F96.3 --moves _)
[[ "$sel" == "F96.2" ]] && pass "_ is an alias for ^" || fail "_ should reach F96.2, got '$sel'"
sel=$(gsel --cursor F96.3 --moves 0)
[[ "$sel" == "F96.2" ]] && pass "0 is an alias for ^" || fail "0 should reach F96.2, got '$sel'"
sel=$(gsel --cursor F96.1 --moves G)
[[ "$sel" == "F96.6" ]] && pass "G jumps to the last layer ($sel)" || fail "G should reach F96.6, got '$sel'"

# An unknown cursor falls back rather than rendering a selectionless graph.
sel=$(gsel --cursor F96.999)
[[ "$sel" == "F96.4" ]] && pass "an unknown cursor id falls back to the default" || fail "stale cursor kept: '$sel'"

# The viewport follows the selection: in a terminal narrower than the graph, the
# selected node must be on screen.
narrow() { TASKPUMP_PUMP_STATE_FILE="$GPS" TASKPUMP_TASKS_DIR="$GTD" TASKPUMP_MONITOR_COLS=40 \
               "$CLI" --tab graph --cursor "$1" 2>/dev/null | strip_ansi; }
narrow F96.5 | grep -q '┃ F96.5 ' && pass "viewport pans to keep the selection visible" \
    || fail "selection off-screen in a narrow terminal:\n$(narrow F96.5)"

# ── Test 19: `o` opens the selected task's file ──────────────────────────────
# Asserted through --moves for the same reason cursor movement is: no pty. The
# spawn is deliberately detached from the monitor, so the stub's marker file is
# polled rather than awaited.
echo "--- Test 19: open the selected task's file ---"
MARK="$TMP/opened.txt"
cat >| "$BIN/fake-editor" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$MARK"
EOF
chmod +x "$BIN/fake-editor"
gopen() {  # $1 = cursor, $2 = moves
    : >| "$MARK"
    TASKPUMP_PUMP_STATE_FILE="$GPS" TASKPUMP_TASKS_DIR="$GTD" TASKPUMP_MONITOR_COLS=100 \
        TASKPUMP_MONITOR_OPEN_CMD="$BIN/fake-editor --open" \
        "$CLI" --tab graph --cursor "$1" --moves "$2" >/dev/null 2>&1
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$MARK" ]] && break; sleep 0.2; done
    cat "$MARK" 2>/dev/null
}
opened=$(gopen F96.5 o)
[[ "$opened" == "--open $GTD/F96.5.md" ]] \
    && pass "o opens the selected task's file ($opened)" \
    || fail "o should have opened $GTD/F96.5.md, got '$opened'"
# Moving first, then opening, must follow the cursor rather than the start id.
opened=$(gopen F96.2 jo)
[[ "$opened" == "--open $GTD/F96.4.md" ]] \
    && pass "o follows the cursor after a move ($opened)" \
    || fail "o should have opened F96.4 after ↓, got '$opened'"
# A task with no file on disk must not spawn anything.
opened=$(gopen F96.4 '')
[[ -z "$opened" ]] && pass "no open command runs without the o key" \
    || fail "spawned an editor unprompted: '$opened'"

# ── Test 20: one live branch elects ONE running task ─────────────────────────
# Phase grain drains a phase serially, so a branch routinely holds a stale claim
# alongside the one being worked. Painting both ▶ made the GRAPH tab disagree
# with SESSIONS about how much was moving.
echo "--- Test 20: one running task per live branch ---"
claim() {  # <id> <status> <branch> <claimed_at> <heartbeat> [blocker ...]
    local id="$1" st="$2" by="$3" ca="$4" hb="$5"; shift 5
    {
        echo '---'; echo "id: \"$id\""; echo 'phase: "F97"'; echo "status: $st"
        echo "claimed_by: $by"; echo "claimed_at: \"$ca\""
        echo "last_heartbeat_ts: $hb"; echo 'turn_budget_remaining: 4'
        echo "goal: \"the $id outcome\""
        if (( $# )); then echo 'blockers:'; for b in "$@"; do echo "  - \"$b\""; done
        else echo 'blockers: []'; fi
        echo '---'; echo body
    } >| "$CTD/$id.md"
}
CTD="$TMP/ctasks"; mkdir -p "$CTD"
claim F97.1 done        ""        ""                     null
# Both claimed by feat/f97; .3 heartbeated more recently, so it is the live one.
claim F97.2 in_progress feat/f97  "2026-08-05T10:00:00Z" '"2026-08-05T10:30:00Z"' F97.1
claim F97.3 in_progress feat/f97  "2026-08-05T11:00:00Z" '"2026-08-05T11:30:00Z"' F97.1
CPS="$TMP/claim-pump.state"
printf '%s' '{"phases":"F97","started_at":"2026-08-05T09:00:00Z","status":"running"}' >| "$CPS"
cgraph=$(TASKPUMP_TASKS_DIR="$CTD" "$TP_ROOT/libexec/tp-dag-render" \
             --phases F97 --no-color --live-branches feat/f97 2>/dev/null)
runners=$(grep -o '▶' <<<"$cgraph" | wc -l)
[[ "$runners" == "1" ]] && pass "exactly one node renders ▶ ($runners)" \
    || fail "expected 1 running node, got $runners:\n$cgraph"
grep -qE "│ F97\.3 +▶ │" <<<"$cgraph" && pass "the newest heartbeat wins the election" \
    || fail "F97.3 should be the running one:\n$cgraph"
grep -qE "│ F97\.2 +⧗ │" <<<"$cgraph" && pass "the stale claim falls back to ⧗ parked" \
    || fail "F97.2 should be parked:\n$cgraph"
# A claim that never heartbeated still competes, on claimed_at.
claim F97.4 in_progress feat/f97b "2026-08-05T12:00:00Z" null F97.1
nohb=$(TASKPUMP_TASKS_DIR="$CTD" "$TP_ROOT/libexec/tp-dag-render" \
           --phases F97 --no-color --live-branches feat/f97b 2>/dev/null)
grep -qE "│ F97\.4 +▶ │" <<<"$nohb" && pass "a never-heartbeated claim falls back to claimed_at" \
    || fail "F97.4 should be running:\n$nohb"
# --claims is the same election, and is what the SESSIONS tab reads.
cl=$(TASKPUMP_TASKS_DIR="$CTD" "$TP_ROOT/libexec/tp-dag-render" --claims 2>/dev/null)
[[ "$(awk -F'\t' '$1=="feat/f97"{print $2}' <<<"$cl")" == "F97.3" ]] \
    && pass "--claims names the same task the canvas paints ▶" \
    || fail "--claims disagrees with the canvas:\n$cl"

# ── Test 21: SESSIONS cursor ─────────────────────────────────────────────────
echo "--- Test 21: session cursor ---"
SFR="$TMP/sessroot"; mkdir -p "$SFR/.worktrees/feat/f97" "$SFR/.worktrees/feat/f97b"
printf '%s\n' '{"type":"assistant","message":{"content":[{"text":"alpha log"}]}}' \
    >| "$SFR/.worktrees/feat/f97/.arachne-agent.log"
printf '%s\n' '{"type":"assistant","message":{"content":[{"text":"beta log"}]}}' \
    >| "$SFR/.worktrees/feat/f97b/.arachne-agent.log"
cat >| "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    '{{.Names}}|{{.State}}|{{.Status}}')
      echo 'arachne-agent-feat-f97|running|Up 3 minutes'
      echo 'arachne-agent-feat-f97b|running|Up 9 minutes'; exit 0 ;;
    '{{.Names}}') echo 'arachne-agent-feat-f97'; echo 'arachne-agent-feat-f97b'; exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$BIN/docker"
SCACHE="$TMP/sess-cursor.tsv"
smon() { TASKPUMP_MONITOR_REPO_ROOT="$SFR" TASKPUMP_TASKS_DIR="$CTD" \
         TASKPUMP_PUMP_STATE_FILE="$CPS" TASKPUMP_MONITOR_SESS_CACHE="$SCACHE" \
         TASKPUMP_MONITOR_COLS=140 "$CLI" "$@" 2>/dev/null | strip_ansi; }
smon >/dev/null; sleep 2; smon >/dev/null      # warm the background session cache
sess=$(smon)
# The row's task comes from the LEDGER's live claim, not the (empty) manifest.
grep -qE 'feat-f97 .*F97\.3:in_progress' <<<"$sess" \
    && pass "a session row names the task its branch is actually on" \
    || fail "session row did not resolve the live claim:\n$sess"
grep -q '▸ ' <<<"$sess" && pass "the selected session is marked" || fail "no selection marker:\n$sess"
[[ "$(grep -c '▸ ' <<<"$sess")" == "1" ]] && pass "exactly one session is marked" \
    || fail "more than one row marked:\n$sess"
# The top bar describes the selection, mirroring the GRAPH status bar.
grep -q 'the F97.3 outcome' <<<"$sess" && pass "the top bar shows the selected session's goal" \
    || fail "no goal in the session detail bar:\n$sess"
# ↓ moves the selection to the next session, and its detail follows.
down=$(smon --moves j)
grep -qE '▸ ● feat-f97b' <<<"$down" && pass "↓ selects the next session" \
    || fail "↓ did not move the session cursor:\n$down"
grep -q 'the F97.4 outcome' <<<"$down" && pass "the detail bar follows the selection" \
    || fail "detail bar did not follow:\n$down"
# ↑ past the top and ↓ past the bottom clamp rather than wrapping or vanishing.
grep -qE '▸ ● feat-f97\b' <<<"$(smon --moves kkkk)" && pass "↑ clamps at the first session" \
    || fail "↑ ran off the top"
grep -qE '▸ ● feat-f97b' <<<"$(smon --moves jjjj)" && pass "↓ clamps at the last session" \
    || fail "↓ ran off the bottom"
# gg / G, as on the GRAPH tab.
grep -qE '▸ ● feat-f97\b' <<<"$(smon --moves jgg)" && pass "gg selects the first session" \
    || fail "gg did not reach the first session"
grep -qE '▸ ● feat-f97b' <<<"$(smon --moves G)" && pass "G selects the last session" \
    || fail "G did not reach the last session"
printf '#!/usr/bin/env bash\nexit 0\n' >| "$BIN/docker"; chmod +x "$BIN/docker"

# ── Test 22: escape-sequence decoding ────────────────────────────────────────
# read_key is a pure function of the bytes on stdin, so --decode-keys drives it
# directly — no pty, the same trick --moves plays for cursor motion.
#
# WHY so many variants per key: one logical key has SEVERAL encodings and the
# terminal picks between them at runtime. Home arrives as CSI H with cursor keys
# in normal mode, SS3 H in application mode (this host's terminfo declares
# khome=\EOH, kend=\EOF, kcuu1=\EOA — the SS3 forms), CSI 1~ / CSI 7~ from the
# linux-console and rxvt lineages, and any of those gains a parameter once a
# modifier is held (terminfo kHOM=\E[1;2H, kEND=\E[1;2F). The decoder used to
# read a FIXED two bytes after ESC, which matched only the 3-byte CSI forms: it
# dropped \EOH entirely, and dropped \E[1~ *and* stranded its trailing "~" to be
# read as a phantom keypress on the next iteration.
echo "--- Test 22: key decoding ---"
dk_is() {  # $1 = bytes (printf %b escapes), $2 = expected tokens one per line, $3 = label
    local want n got
    want=$(printf '%b' "$2")            # \n in the expectation is a real newline
    n=$(grep -c '' <<<"$want")          # read exactly as many keys as expected
    got=$(printf '%b' "$1" | "$CLI" --decode-keys "$n" 2>/dev/null)
    [[ "$got" == "$want" ]] && pass "$3" \
        || fail "$3 — expected [${want//$'\n'/,}] got [${got//$'\n'/,}]"
}

# Home and End, in every form a terminal may emit. \EOH / \EOF are the ones the
# reported bug was about: terminfo says that is what this host sends.
dk_is '\033[H'  HOME 'CSI H decodes to HOME'
dk_is '\033OH'  HOME 'SS3 H (application cursor mode) decodes to HOME'
dk_is '\033[1~' HOME 'CSI 1~ decodes to HOME'
dk_is '\033[7~' HOME 'CSI 7~ decodes to HOME'
dk_is '\033[F'  END  'CSI F decodes to END'
dk_is '\033OF'  END  'SS3 F (application cursor mode) decodes to END'
dk_is '\033[4~' END  'CSI 4~ decodes to END'
dk_is '\033[8~' END  'CSI 8~ decodes to END'

# Arrows in both modes — the same DECCKM split, and the reason the fix is a
# decoder rewrite rather than two extra Home/End cases.
dk_is '\033[A' UP    'CSI A decodes to UP'
dk_is '\033[B' DOWN  'CSI B decodes to DOWN'
dk_is '\033[C' RIGHT 'CSI C decodes to RIGHT'
dk_is '\033[D' LEFT  'CSI D decodes to LEFT'
dk_is '\033OA' UP    'SS3 A decodes to UP'
dk_is '\033OB' DOWN  'SS3 B decodes to DOWN'
dk_is '\033OC' RIGHT 'SS3 C decodes to RIGHT'
dk_is '\033OD' LEFT  'SS3 D decodes to LEFT'

dk_is '\033[Z'  STAB 'CSI Z decodes to Shift-Tab'
dk_is '\033[5~' PGUP 'CSI 5~ decodes to PGUP'
dk_is '\033[6~' PGDN 'CSI 6~ decodes to PGDN'

# A modifier adds parameters; the key is still named by the final byte (or, for
# the tilde family, by the FIRST parameter). These are the exact byte strings
# this host's terminfo lists for Shift-Home / Shift-End.
dk_is '\033[1;2H' HOME 'Shift-Home (CSI 1;2H) still decodes to HOME'
dk_is '\033[1;2F' END  'Shift-End (CSI 1;2F) still decodes to END'
dk_is '\033[1;5H' HOME 'Ctrl-Home (CSI 1;5H) still decodes to HOME'
dk_is '\033[5;2~' PGUP 'Shift-PgUp (CSI 5;2~) still decodes to PGUP'

# NO STRAY BYTE: a sequence must be consumed to its final byte. If the trailing
# "~" survived, the next read would see it as a keypress instead of nothing.
dk_is '\033[1~'   'HOME\nNONE' 'CSI 1~ leaves nothing behind'
dk_is '\033[1~x'  'HOME\nx'    'a key typed after CSI 1~ is read next, intact'
dk_is '\033OHq'   'HOME\nq'    'a key typed after SS3 H is read next, intact'
dk_is '\033[5~\033[6~' 'PGUP\nPGDN' 'back-to-back sequences decode independently'

# Non-escape keys are unchanged: Enter is an empty successful read (read's own
# delimiter) and must stay distinguishable from the interval timeout.
dk_is 'q'    q      'a plain key passes through'
dk_is '\n'   ENTER  'Enter decodes to ENTER, not to a timeout'
dk_is '\033' ESC    'a lone ESC decodes to ESC'
dk_is ''     NONE   'no input decodes to nothing'

"$CLI" --decode-keys nine >/dev/null 2>&1 && fail "--decode-keys accepted a non-count" \
    || pass "--decode-keys rejects a non-numeric count"

# The live key loop needs a pty, so the HOME/END arms of the two tab keymaps are
# pinned at the source level. This is the join the bug report was about: decoding
# HOME is only useful if GRAPH routes it HORIZONTALLY (first node in the layer,
# like ^) while gg/G stay vertical, and SESSIONS — which has no horizontal axis —
# keeps it as first/last session.
arm_has() {  # true when one line of the monitor holds both literals (no regex)
    awk -v a="$1" -v b="$2" 'index($0,a) && index($0,b) { ok=1 } END { exit !ok }' "$CLI"
}
arm_has 'HOME)' "graph_move '^'" \
    && pass "GRAPH routes Home horizontally (first node in the layer)" \
    || fail "GRAPH Home arm no longer calls graph_move '^'"
arm_has 'END)' "graph_move '\$'" \
    && pass "GRAPH routes End horizontally (last node in the layer)" \
    || fail "GRAPH End arm no longer calls graph_move '\$'"
arm_has 'HOME)' 'SESS_SEL=0' \
    && pass "SESSIONS keeps Home as the first session" || fail "SESSIONS Home arm changed"
arm_has 'END)' 'SESS_SEL=999999' \
    && pass "SESSIONS keeps End as the last session" || fail "SESSIONS End arm changed"

# ── Test 23: the colour system admits no basic-ANSI ──────────────────────────
# Rule R3. Basic-ANSI numbers (30-37, 90-97) and reverse video resolve through
# the terminal's theme, so they cannot be reasoned about or checked for
# contrast: under Catppuccin Mocha `32m` is #a6e3a1, a bright pastel that could
# not sit beside the graph's #5FAF5F — which is exactly the clash this system
# was written to delete. This guard is what stops one creeping back in.
echo "--- Test 23: no basic-ANSI colour ---"
offenders=$(grep -nE $'\033\\[[0-9;]*(3[0-7]|9[0-7]|7)m' "$CLI" | grep -v '^\s*#' || true)
[[ -z "$offenders" ]] && pass "arachne-monitor emits no basic-ANSI colour or reverse video" \
    || fail "basic-ANSI colour reintroduced:\n$offenders"
# Every sequence must also re-open with 0 (R1): SGR dim/bold are sticky, and a
# leaked attribute has silently washed out both the DAG and every gauge fill.
leaky=$(grep -oE $'\033\\[[0-9;]+m' "$CLI" | grep -vE $'\033\\[0([;m])' || true)
[[ -z "$leaky" ]] && pass "every colour sequence re-opens with 0" \
    || fail "non-absolute sequences: $(tr -d '\033' <<<"$leaky" | sort -u | tr '\n' ' ')"

# ── Test 24: the tab bar marks the active tab by weight, not by brackets ─────
# The `┤ ├` indicators are gone. Bold weight is now the whole non-colour half of
# the mark (R2) — it is all a --no-color or colour-blind reader has — so it must
# land on exactly the active label. And because a bracket was also doing the
# cell's padding, dropping it can silently move a label: the columns are pinned
# here so switching tabs never reflows the row under the reader's eye.
echo "--- Test 24: tab bar marking ---"
strong_sgr=$'\033[0;1;38;5;252m'   # C_STRONG — active
rule_sgr=$'\033[0;38;5;242m'       # C_RULE   — inactive, no bold
sess_bar=$("$CLI" 2>/dev/null | grep 'SESSIONS.*GRAPH')
graph_bar=$("$CLI" --tab graph 2>/dev/null | grep 'SESSIONS.*GRAPH')

bold_hits=$(grep -oF "$strong_sgr" <<<"$sess_bar" | wc -l)
[[ "$bold_hits" -eq 1 ]] && grep -qF "$strong_sgr  SESSIONS" <<<"$sess_bar" \
    && grep -qF "$rule_sgr  GRAPH" <<<"$sess_bar" \
    && pass "SESSIONS active: bold on its label, none on GRAPH" \
    || fail "SESSIONS tab weight wrong (${bold_hits} bold runs):\n$(cat -v <<<"$sess_bar")"
bold_hits=$(grep -oF "$strong_sgr" <<<"$graph_bar" | wc -l)
[[ "$bold_hits" -eq 1 ]] && grep -qF "$strong_sgr  GRAPH" <<<"$graph_bar" \
    && grep -qF "$rule_sgr  SESSIONS" <<<"$graph_bar" \
    && pass "GRAPH active: bold on its label, none on SESSIONS" \
    || fail "GRAPH tab weight wrong (${bold_hits} bold runs):\n$(cat -v <<<"$graph_bar")"

if grep -qF '┤' <<<"$sess_bar$graph_bar" || grep -qF '├' <<<"$sess_bar$graph_bar"; then
    fail "bracket indicator still on the tab row:\n$sess_bar\n$graph_bar"
else
    pass "no bracket glyph on the tab row"
fi

# Columns must not depend on which tab is selected.
col_of() { awk -v n="$2" 'NR==1 { print index($0, n) }' <<<"$1"; }
s_strip=$(strip_ansi <<<"$sess_bar"); g_strip=$(strip_ansi <<<"$graph_bar")
sc_a=$(col_of "$s_strip" 'SESSIONS'); sc_b=$(col_of "$g_strip" 'SESSIONS')
gc_a=$(col_of "$s_strip" 'GRAPH');    gc_b=$(col_of "$g_strip" 'GRAPH')
[[ "$sc_a" -gt 0 && "$gc_a" -gt 0 && "$sc_a" == "$sc_b" && "$gc_a" == "$gc_b" ]] \
    && pass "tab labels hold their columns across a switch (SESSIONS@$sc_a GRAPH@$gc_a)" \
    || fail "tab labels shift on switch: SESSIONS $sc_a→$sc_b, GRAPH $gc_a→$gc_b"

# The enumerated key hint is gone; one muted affordance points at the overlay.
grep -q ':help' <<<"$s_strip" && grep -q ':help' <<<"$g_strip" \
    && pass "tab row carries the :help affordance on both tabs" \
    || fail "no :help affordance:\n$s_strip\n$g_strip"
grep -qE 'q quit|Enter open|switch' <<<"$s_strip$g_strip" \
    && fail "tab row still enumerates keys:\n$s_strip\n$g_strip" \
    || pass "tab row enumerates no keys"

# ── Test 25: gt/gT switch tab; the arrows never do ───────────────────────────
# Pinned at source level with Test 22's arm_has, for the same reason: the live
# key loop needs a pty. The `--moves` seam cannot stand in here — render_all
# branches on TAB and *then* calls the tab's replayer, so a replayed tab switch
# could not change which renderer ran without restructuring the one-shot path.
echo "--- Test 25: gt/gT tab switching ---"

# The bug this closes: ← / → switched tab on SESSIONS while driving the node
# cursor on GRAPH, so the same key both navigated and teleported you off the
# page depending on where you were. Every case arm naming an arrow must now be
# a graph_move — there is no other legitimate consumer.
arrow_arms=$(grep -nE '^[[:space:]]*[^#]*\b(LEFT|RIGHT)\)' "$CLI" || true)
stray_arrows=$(printf '%s\n' "$arrow_arms" | grep -v 'graph_move' | grep -v '^$' || true)
[[ -n "$arrow_arms" ]] && [[ -z "$stray_arrows" ]] \
    && pass "← / → drive only the GRAPH node cursor — no arm switches tab" \
    || fail "an arrow key arm no longer routes to graph_move:\n$stray_arrows"

# ...and specifically that the SESSIONS switch arm dropped them, rather than the
# arrows merely having moved to some other tab-switching arm.
arm_has 'LEFT' 'tab_switch' && fail "an arrow arm still switches tab" \
    || pass "SESSIONS tab-switch arm no longer names LEFT"
arm_has 'RIGHT' 'tab_switch' && fail "an arrow arm still switches tab" \
    || pass "SESSIONS tab-switch arm no longer names RIGHT"
arm_has 'RIGHT)' 'TAB=1' && fail "the old SESSIONS ←/→ tab-switch arm is still present" \
    || pass "the old '\$'\\t'|STAB|LEFT|RIGHT) TAB=1' arm is gone"

# `g` is the prefix; t and T must resolve inside it, beside gg. If they leaked to
# the per-tab keymaps instead, `gt` would move the cursor and then switch tab.
arm_has 't)' 'tab_switch next' \
    && pass "the g-prefix block resolves t → next tab" \
    || fail "gt does not resolve to a next-tab switch in the g-prefix block"
arm_has 'T)' 'tab_switch prev' \
    && pass "the g-prefix block resolves T → previous tab" \
    || fail "gT does not resolve to a previous-tab switch in the g-prefix block"

# One switch function, four entry points, both tabs: the SCROLL/PAN reset is the
# whole reason it exists, so an arm that sets TAB by hand is the regression.
[[ "$(grep -cE '^[[:space:]]*[^#]*tab_switch (next|prev)' "$CLI")" -ge 6 ]] \
    && pass "Tab/Shift-Tab/gt/gT on both tabs all route through tab_switch" \
    || fail "fewer than six tab_switch call sites — an arm bypasses it"
raw_tab_sets=$(grep -nE '^[[:space:]]*[^#]*(\$.\\t.|STAB)\).*TAB=' "$CLI" || true)
[[ -z "$raw_tab_sets" ]] \
    && pass "no tab-switch arm assigns TAB directly (the viewport reset can't be skipped)" \
    || fail "a tab-switch arm sets TAB by hand:\n$raw_tab_sets"

# The reset itself, and the directionality that lets a third tab be added
# without rewriting the arms.
# The function's BEHAVIOUR, not its source text. The monitor cannot be sourced
# (it renders on load), so lift the definition out and run it standalone: the
# viewport reset is the whole point of centralising the switch, and a grep for
# `SCROLL=0` would still pass if the assignment moved behind a condition.
tab_switch_says() {  # $1 = start TAB, $2 = direction → "TAB SCROLL PAN"
    bash -c '
        eval "$(sed -n "/^TAB_COUNT=/,/^}/p" "$0")"
        TAB="$1"; SCROLL=42; PAN=17
        tab_switch "$2"
        printf "%s %s %s" "$TAB" "$SCROLL" "$PAN"
    ' "$CLI" "$1" "$2"
}
[[ "$(tab_switch_says 0 next)" == "1 0 0" ]] \
    && pass "tab_switch next from SESSIONS lands on GRAPH with the viewport zeroed" \
    || fail "tab_switch 0 next → $(tab_switch_says 0 next), want '1 0 0'"
[[ "$(tab_switch_says 1 next)" == "0 0 0" ]] \
    && pass "tab_switch next wraps GRAPH → SESSIONS" \
    || fail "tab_switch 1 next → $(tab_switch_says 1 next), want '0 0 0'"
[[ "$(tab_switch_says 0 prev)" == "1 0 0" ]] \
    && pass "tab_switch prev from SESSIONS wraps back to GRAPH" \
    || fail "tab_switch 0 prev → $(tab_switch_says 0 prev), want '1 0 0'"
[[ "$(tab_switch_says 1 prev)" == "0 0 0" ]] \
    && pass "tab_switch prev from GRAPH lands on SESSIONS" \
    || fail "tab_switch 1 prev → $(tab_switch_says 1 prev), want '0 0 0'"
# Never out of range, whatever it is handed — an out-of-range TAB would render
# the SESSIONS tab while the tab bar claimed otherwise.
[[ "$(tab_switch_says 0 '')" == "1 0 0" ]] \
    && pass "tab_switch defaults to next when handed no direction" \
    || fail "tab_switch with no direction → $(tab_switch_says 0 '')"
grep -q 'TAB_COUNT' <(sed -n '/^tab_switch()/,/^}/p' "$CLI") \
    && pass "tab_switch is directional over TAB_COUNT, not a two-tab toggle" \
    || fail "tab_switch hardcodes a two-tab toggle"

# The documented keymap is the one the code implements. That documentation is
# the ? panel and nothing else — the leading comment block deliberately stopped
# restating it when the overlay landed, so a second copy cannot go stale. These
# assertions therefore read the panel, not `--help`.
b25_sess=$(TASKPUMP_MONITOR_COLS=100 "$CLI" --show-help --tab sessions 2>/dev/null | strip_ansi)
b25_graph=$(TASKPUMP_MONITOR_COLS=100 "$CLI" --show-help --tab graph 2>/dev/null | strip_ansi)
grep -qE '^│ gt gT ' <<<"$b25_sess" && grep -qE '^│ gt gT ' <<<"$b25_graph" \
    && pass "the help panel binds gt / gT on both tabs" \
    || fail "the help panel does not document gt / gT:\n$b25_sess"
# The arrows are the GRAPH tab's node cursor, so SESSIONS must say so rather
# than leaving a reader to try them and watch the tab change under them.
grep -E '^│ ← →' <<<"$b25_sess" | grep -q 'nothing here' \
    && pass "SESSIONS help states the arrows do nothing there" \
    || fail "SESSIONS help still binds ← → to something:\n$(grep '←' <<<"$b25_sess")"

# ── Test 26: top-region vertical rhythm ──────────────────────────────────────
# Three facts about the fixed top, all of them spacing: one blank line under the
# tab row on BOTH tabs; notes that WRAP (they used to be cut with an "…") and
# flow on past the disk sub-info instead of dead-ending above it; and one blank
# line closing the whole composed block. The pump row is located by content, not
# by row number — the tab bar above it is being rewritten independently.
echo "--- Test 26: top-region vertical rhythm ---"
make_usage_stub 40 50
# A pump state so the `pump[…]` line renders at all; its counts come from a
# pre-seeded cache with a huge TTL so no background frontier scan is kicked off.
PS24="$TMP/pump24.state"
printf '%s' '{"phases":"F24","started_at":"2026-08-05T09:00:00Z","status":"running","open_tasks":3,"ceiling":95}' >| "$PS24"
PC24="$TMP/pump24-cache.tsv"; printf 'ELIG\t1\nOPEN\t3\n' >| "$PC24"
run24() {  # $1 = cols  $2 = notes file  $3 = notes tail (default 6)
  TASKPUMP_MONITOR_DISK=1 TASKPUMP_MONITOR_DISK_CACHE="$DCACHE" TASKPUMP_MONITOR_DISK_TTL=99999 \
  TASKPUMP_MONITOR_MAIN_ROOT="$FAKE_MAIN" DF_AVAIL_KB=52428800 \
  TASKPUMP_PUMP_STATE_FILE="$PS24" TASKPUMP_MONITOR_PUMP_CACHE="$PC24" TASKPUMP_MONITOR_PUMP_TTL=99999 \
  TASKPUMP_TASKS_DIR="$TMP/no-such-tasks" \
  TASKPUMP_MONITOR_COLS="$1" TASKPUMP_MONITOR_NOTES_FILE="$2" TASKPUMP_MONITOR_NOTES_TAIL="${3:-6}" \
  "$CLI" 2>/dev/null | strip_ansi; }
row_at() { sed -n "${2}p" <<<"$1" 2>/dev/null; }   # $1 = text, $2 = 1-based row

# (a) A long note wraps instead of gaining an "…", and its tail is the NEXT row.
# Narrow, so the notes column stacks at column 0 and the indent is assertable.
NF24="$TMP/notes24.md"
printf -- '- 14:02  the host oauth token expired mid-run and every agent container stalled waiting on SENTINELTAIL\n' >| "$NF24"
w24=$(run24 60 "$NF24")
grep -q 'SENTINELTAIL' <<<"$w24" && pass "a long note keeps its tail" || fail "note tail cut off:\n$w24"
grep -qE 'oauth token.*…' <<<"$w24" && fail "the long note is still truncated with an …:\n$w24" \
    || pass "the long note is wrapped, not truncated"
head_row=$(awk '/^- 14:02/{print NR; exit}' <<<"$w24")
tail_row=$(awk '/SENTINELTAIL/{print NR; exit}' <<<"$w24")
[[ -n "$head_row" && "$tail_row" == "$((head_row + 1))" ]] \
    && pass "the wrapped tail lands on the line after the stamp (rows $head_row/$tail_row)" \
    || fail "wrap did not spill onto the next line: head=$head_row tail=$tail_row:\n$w24"
# Continuation is indented past the "- HH:MM  " stamp, so the timestamp keeps a
# column of its own and one entry stays visually distinct from the next.
grep -qE '^ {9}[^ ].*SENTINELTAIL' <<<"$w24" \
    && pass "the continuation line is indented under the note text" \
    || fail "continuation not indented past the stamp:\n$w24"

# (b)+(d) Wide terminal: notes continue BELOW the disk sub-info rows, and one
# blank line closes the composed block.
MF24="$TMP/notes24-many.md"
printf -- '- 09:%02d  note-%02d body\n' 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9 10 10 11 11 12 12 >| "$MF24"
m24=$(run24 200 "$MF24" 12)
wt_row=$(awk '/worktrees 11/{print NR; exit}' <<<"$m24")
dk_row=$(awk '/docker img /{print NR; exit}' <<<"$m24")
last_note=$(awk '/note-[0-9]+ body/{r=NR} END{print r+0}' <<<"$m24")
[[ -n "$wt_row" && -n "$dk_row" && "$last_note" -gt "$dk_row" && "$last_note" -gt "$wt_row" ]] \
    && pass "notes flow on past the disk sub-info (last note row $last_note > docker row $dk_row)" \
    || fail "notes dead-end above the disk column: worktrees=$wt_row docker=$dk_row last-note=$last_note:\n$m24"
below=$(row_at "$m24" "$((last_note + 1))")
[[ "$last_note" -gt 0 && -z "${below//[[:space:]]/}" ]] \
    && pass "a blank line closes the composed top block" \
    || fail "no blank line under the composed block: [$below]"

# (c) Exactly one blank row between the tab row and the pump row — the pump row
# is found by content so no assertion here depends on the tab bar's text.
p_row=$(awk '/pump\[/{print NR; exit}' <<<"$m24")
above1=$(row_at "$m24" "$((p_row - 1))"); above2=$(row_at "$m24" "$((p_row - 2))")
[[ -n "$p_row" && -z "${above1//[[:space:]]/}" && -n "${above2//[[:space:]]/}" ]] \
    && pass "exactly one blank line separates the tab row from the pump line" \
    || fail "tab→pump spacing wrong (pump row $p_row): above=[$above1] above-above=[$above2]"
# The GRAPH tab breathes the same way — the two tops must not drift apart.
g24=$(TASKPUMP_PUMP_STATE_FILE="$GPS" TASKPUMP_TASKS_DIR="$GTD" TASKPUMP_MONITOR_PUMP_CACHE="$PC24" \
      TASKPUMP_MONITOR_PUMP_TTL=99999 TASKPUMP_MONITOR_COLS=120 "$CLI" --tab graph 2>/dev/null | strip_ansi)
gp_row=$(awk '/pump\[/{print NR; exit}' <<<"$g24")
gab1=$(row_at "$g24" "$((gp_row - 1))"); gab2=$(row_at "$g24" "$((gp_row - 2))")
[[ -n "$gp_row" && -z "${gab1//[[:space:]]/}" && -n "${gab2//[[:space:]]/}" ]] \
    && pass "the GRAPH tab gets the same blank line under the tabs" \
    || fail "GRAPH tab→pump spacing wrong (pump row $gp_row): above=[$gab1] above-above=[$gab2]"

# (e) NOTES_TAIL still counts ENTRIES — a wrapped note must not eat two slots.
TF24="$TMP/notes24-tail.md"
{ printf -- '- 08:00  oldest-entry\n'
  printf -- '- 08:01  second entry deliberately long enough to need two display lines all by itself\n'
  printf -- '- 08:02  third entry also deliberately long enough to need two display lines all by itself\n'; } >| "$TF24"
t24=$(run24 60 "$TF24" 2)
grep -q 'oldest-entry' <<<"$t24" && fail "NOTES_TAIL counted display lines, not entries:\n$t24" \
    || pass "NOTES_TAIL=2 drops the third-oldest entry"
grep -q 'second entry' <<<"$t24" && grep -q 'third entry' <<<"$t24" \
    && pass "NOTES_TAIL=2 shows two ENTRIES even when each wraps to two lines" \
    || fail "a wrapped entry cost more than one tail slot:\n$t24"

# ── Test 27: the help panel (? overlay / :help) ──────────────────────────────
# The overlay itself needs a pty, so --show-help is its seam: it prints exactly
# what help_lines() paints, for the tab --tab picked. What is asserted is the
# property the old always-on hint line could not have had — the two tabs
# document DIFFERENT keymaps, each naming its own axis, while still agreeing on
# the handful of keys that really are shared.
echo "--- Test 27: help panel ---"
"$CLI" --show-help --tab graph >/dev/null 2>&1 && pass "--show-help exits 0" || fail "--show-help exited non-zero"
hsess=$(TASKPUMP_MONITOR_COLS=100 "$CLI" --show-help --tab sessions 2>/dev/null | strip_ansi)
hgraph=$(TASKPUMP_MONITOR_COLS=100 "$CLI" --show-help --tab graph 2>/dev/null | strip_ansi)
[[ -n "$hsess" && "$hsess" != "$hgraph" ]] && pass "the two tabs get different help panels" \
    || fail "sessions and graph help are identical:\n$hsess"
grep -q 'SESSIONS tab keys' <<<"$hsess"  && pass "the sessions panel is titled for its tab" || fail "no SESSIONS title:\n$hsess"
grep -q 'GRAPH tab keys'    <<<"$hgraph" && pass "the graph panel is titled for its tab"    || fail "no GRAPH title:\n$hgraph"
grep -q '┌' <<<"$hgraph" && grep -q '└' <<<"$hgraph" && pass "the panel is a bordered box" || fail "no box border:\n$hgraph"

# Each panel names its OWN tab's keys — and only its own.
grep -q 'o Enter' <<<"$hgraph" && pass "graph help documents o (open the selected task)" \
    || fail "graph help missing the o key:\n$hgraph"
grep -q '\$ End' <<<"$hgraph" && pass "graph help documents \$ (last node in the layer)" \
    || fail "graph help missing the \$ key:\n$hgraph"
grep -q 'o Enter' <<<"$hsess" && fail "sessions help lists the graph-only o key" \
    || pass "sessions help omits the graph-only keys"
grep -q '│ Enter ' <<<"$hsess" && pass "sessions help documents Enter (open the session's task)" \
    || fail "sessions help missing Enter:\n$hsess"
grep -q 'next session' <<<"$hsess" && pass "sessions help describes the session cursor" \
    || fail "sessions help says nothing about the session cursor:\n$hsess"
# ...and both name the keys that are genuinely shared, including B's tab switch.
for tabname in sessions graph; do
    h=$([[ "$tabname" == graph ]] && printf '%s' "$hgraph" || printf '%s' "$hsess")
    grep -q 'gt gT' <<<"$h" && pass "$tabname help documents gt/gT" || fail "$tabname help missing gt/gT:\n$h"
    grep -q 'q :q'  <<<"$h" && pass "$tabname help documents q"     || fail "$tabname help missing q:\n$h"
done

# Width is bounded by the terminal, and sized to the content when there is room.
panel_w() { TASKPUMP_MONITOR_COLS="$1" "$CLI" --show-help --tab "$2" 2>/dev/null | strip_ansi \
    | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }'; }
w48=$(panel_w 48 graph)
[[ "$w48" -gt 0 && "$w48" -le 48 ]] && pass "panel respects TASKPUMP_MONITOR_COLS=48 (${w48} cols)" \
    || fail "panel overflowed a 48-column terminal: ${w48}"
w200=$(panel_w 200 graph)
[[ "$w200" -gt 48 && "$w200" -lt 200 ]] && pass "a wide terminal sizes the panel to its content (${w200} cols)" \
    || fail "panel not content-sized at 200 columns: ${w200}"

# The hint lines the panel replaced are gone — and the blocks that held them
# still emit TWO lines each. The watch loop measures the top region's height
# from those blocks, so a changed line count silently shifts the viewport.
gtop=$("$CLI" --tab graph 2>/dev/null | strip_ansi)
stop=$("$CLI" 2>/dev/null | strip_ansi)
# Matched on the tail of each removed string, not its head: the tab bar carries
# a hint of its own (a different surface, removed separately) whose opening
# clause reads the same.
grep -q 'gg/G layers' <<<"$gtop" && fail "the graph detail hint line is still painted" \
    || pass "graph detail hint line removed"
grep -q 'Enter open · Tab graph' <<<"$stop" && fail "the sessions detail hint line is still painted" \
    || pass "sessions detail hint line removed"
after() {  # $1 = a literal on the anchor line, $2 = how many lines past it
    awk -v pat="$1" -v off="$2" 'index($0,pat) && !f { f=NR } f && NR==f+off { print; exit }'
}
gap=$(after '✓ done' 1 <<<"$gtop")
[[ -z "${gap// }" ]] && pass "the graph detail block's second line is now blank" \
    || fail "expected a blank second line, got '$gap'"
[[ "$(after '✓ done' 2 <<<"$gtop")" == ─* ]] && pass "the graph top region keeps its height (rule 2 lines on)" \
    || fail "graph top height changed: '$(after '✓ done' 2 <<<"$gtop")'"
gap=$(after 'no sessions' 1 <<<"$stop")
[[ -z "${gap// }" ]] && pass "the sessions detail block's second line is now blank" \
    || fail "expected a blank second line, got '$gap'"
[[ "$(after 'no sessions' 2 <<<"$stop")" == ─* ]] && pass "the sessions top region keeps its height" \
    || fail "sessions top height changed: '$(after 'no sessions' 2 <<<"$stop")'"

# The live ? and : arms need a pty, so they are pinned at source level — and
# pinned in BOTH keymaps, since help_lines reads $TAB and a tab that never
# reaches it is a tab with no documentation at all.
arm_count() {  # how many lines of the monitor hold BOTH literals
    awk -v a="$1" -v b="$2" 'index($0,a) && index($0,b) { c++ } END { print c+0 }' "$CLI"
}
[[ "$(arm_count "'?')" 'help_overlay')" -ge 2 ]] \
    && pass "both tab keymaps bind ? to the overlay" || fail "the ? arm is missing from a keymap"
[[ "$(arm_count "':')" 'command_input_mode')" -ge 2 ]] \
    && pass "both tab keymaps bind : to the command prompt" || fail "the : arm is missing from a keymap"
arm_has "':')" 'quit) break' && pass ":q breaks the watch loop" || fail "the : arm no longer routes quit to a break"
arm_has 'help|h' 'CMD_ACTION=help' && pass ":help / :h / :? open the panel" || fail ":help verb missing"
arm_has 'q|quit' 'CMD_ACTION=quit' && pass ":q / :quit quit the monitor"    || fail ":quit verb missing"

# ── Test 28: --moves drives the tab switch, on both tabs ─────────────────────
# Until now the tab switch was pinned ONLY by grepping the source for its case
# arm (Test 25): the keymap was asserted, the behaviour never was. The two
# --moves replayers were per-tab, so the one thing they could not express was
# the one thing that moves between tabs.
#
# They are one walker now, so `gt` is replayable — and `gtj` is the assertion
# that matters: switch, then move THAT tab's cursor.
echo "--- Test 28: moves-driven tab switching ---"
active_tab() {  # → SESSIONS | GRAPH, read from the bold mark (never colour alone)
    local raw; raw=$("$@" 2>/dev/null | grep 'SESSIONS.*GRAPH')
    if grep -qF "$strong_sgr  SESSIONS" <<<"$raw"; then printf 'SESSIONS'
    elif grep -qF "$strong_sgr  GRAPH" <<<"$raw"; then printf 'GRAPH'
    else printf 'NONE'; fi
}
tmon() { TASKPUMP_PUMP_STATE_FILE="$GPS" TASKPUMP_TASKS_DIR="$GTD" \
         TASKPUMP_MONITOR_COLS=100 "$CLI" "$@"; }
[[ "$(active_tab tmon)" == SESSIONS ]] && pass "no moves: still on SESSIONS" || fail "default tab moved"
[[ "$(active_tab tmon --moves gt)" == GRAPH ]] \
    && pass "gt from SESSIONS lands on GRAPH" || fail "gt did not switch tab"
[[ "$(active_tab tmon --moves gT)" == GRAPH ]] \
    && pass "gT from SESSIONS lands on GRAPH (two tabs, so prev == next)" || fail "gT did not switch tab"
[[ "$(active_tab tmon --tab graph --moves gt)" == SESSIONS ]] \
    && pass "gt from GRAPH lands on SESSIONS" || fail "gt did not switch back"
[[ "$(active_tab tmon --tab graph --moves gT)" == SESSIONS ]] \
    && pass "gT from GRAPH lands on SESSIONS" || fail "gT did not switch back"
[[ "$(active_tab tmon --moves gtgt)" == SESSIONS ]] \
    && pass "two switches return to the tab you started on" || fail "gtgt did not round-trip"
# `g` is still a prefix and gg is still a motion — neither may switch tab.
[[ "$(active_tab tmon --moves g)" == SESSIONS ]] \
    && pass "a lone g switches nothing" || fail "a bare g switched tab"
[[ "$(active_tab tmon --moves gg)" == SESSIONS ]] \
    && pass "gg is a motion, not a switch" || fail "gg switched tab"

# The whole point: after a switch, a motion drives the tab you landed ON.
# F96.4 is the default cursor (the in_progress task); j walks to its dependent.
sel=$(tmon --moves gtj 2>/dev/null | strip_ansi | awk '/^F96\./ { print $1; exit }')
[[ "$sel" == "F96.6" ]] \
    && pass "gtj switches to GRAPH and then moves the node cursor ($sel)" \
    || fail "cursor after gtj should be F96.6, got '$sel'"
# ...and the body rendered is that tab's body, not the one we started on.
tmon --moves gt 2>/dev/null | strip_ansi | grep -q '┌──' \
    && pass "gt renders the GRAPH body" || fail "gt did not switch which renderer ran"
tmon --tab graph --moves gt 2>/dev/null | strip_ansi | grep -q 'containers running or recently exited' \
    && pass "gt from GRAPH renders the SESSIONS body" || fail "gt did not switch back to the session list"

# The switch zeroes the viewport, because the two tabs' coordinate spaces are
# unrelated. Asserted here through a real render rather than the lifted function.
tmon --tab graph --cursor F96.5 --moves gt 2>/dev/null | strip_ansi | grep -q 'no sessions' \
    && pass "a switch away from a panned GRAPH lands cleanly on SESSIONS" \
    || fail "the tab switch carried GRAPH's viewport into SESSIONS"

# ── Test 29: --show-help follows a replayed switch, per tab ──────────────────
# help_lines reads $TAB, so this is the second, independent check that the
# switch really happened — and the panel is the only keymap in the tree, so
# "which tab does gt land on" has to be answerable without a pty.
echo "--- Test 29: per-tab help after a switch ---"
hp() { TASKPUMP_MONITOR_COLS=100 "$CLI" --show-help "$@" 2>/dev/null | strip_ansi | head -1; }
grep -q 'SESSIONS tab keys' <<<"$(hp)" && pass "--show-help defaults to the SESSIONS panel" \
    || fail "default help panel is not SESSIONS: $(hp)"
grep -q 'GRAPH tab keys' <<<"$(hp --tab graph)" && pass "--show-help --tab graph is the GRAPH panel" \
    || fail "graph help panel wrong: $(hp --tab graph)"
grep -q 'GRAPH tab keys' <<<"$(hp --moves gt)" \
    && pass "--show-help after gt prints the tab it switched to" \
    || fail "help did not follow the switch: $(hp --moves gt)"
grep -q 'SESSIONS tab keys' <<<"$(hp --tab graph --moves gt)" \
    && pass "--show-help after gt from GRAPH prints SESSIONS" \
    || fail "help did not follow the switch back: $(hp --tab graph --moves gt)"
grep -q 'SESSIONS tab keys' <<<"$(hp --moves gg)" \
    && pass "a motion does not change which panel --show-help prints" \
    || fail "gg changed the help panel: $(hp --moves gg)"
# Each panel documents its own axis and omits the other's, whichever way it was
# reached — the property the always-on hint line could not have had.
graph_via_switch=$(TASKPUMP_MONITOR_COLS=100 "$CLI" --show-help --moves gt 2>/dev/null | strip_ansi)
graph_via_flag=$(TASKPUMP_MONITOR_COLS=100 "$CLI" --show-help --tab graph 2>/dev/null | strip_ansi)
[[ "$graph_via_switch" == "$graph_via_flag" ]] \
    && pass "the panel reached by gt is the same one --tab graph prints" \
    || fail "the two routes to the GRAPH panel disagree"

# ── Test 30: the session cursor replays `.` ──────────────────────────────────
# The help panel binds `.` to "back to the first session" on SESSIONS; the old
# per-tab replayer silently ignored it, so the documented key was never run.
echo "--- Test 30: session cursor recentre ---"
cat >| "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    '{{.Names}}|{{.State}}|{{.Status}}')
      echo 'arachne-agent-feat-f97|running|Up 3 minutes'
      echo 'arachne-agent-feat-f97b|running|Up 9 minutes'; exit 0 ;;
    '{{.Names}}') echo 'arachne-agent-feat-f97'; echo 'arachne-agent-feat-f97b'; exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$BIN/docker"
DOTC="$TMP/sess-dot.tsv"
dmon() { TASKPUMP_MONITOR_REPO_ROOT="$SFR" TASKPUMP_TASKS_DIR="$CTD" \
         TASKPUMP_PUMP_STATE_FILE="$CPS" TASKPUMP_MONITOR_SESS_CACHE="$DOTC" \
         TASKPUMP_MONITOR_COLS=140 "$CLI" "$@" 2>/dev/null | strip_ansi; }
dmon >/dev/null; sleep 2; dmon >/dev/null      # warm the background session cache
grep -qE '▸ ● feat-f97b' <<<"$(dmon --moves j)" && pass "j selects the second session" \
    || fail "j did not move the session cursor"
grep -qE '▸ ● feat-f97\b' <<<"$(dmon --moves j.)" \
    && pass ". returns the session cursor to the first row" \
    || fail ". did not recentre the session cursor:\n$(dmon --moves j.)"
printf '#!/usr/bin/env bash\nexit 0\n' >| "$BIN/docker"; chmod +x "$BIN/docker"

# ── Test 31: task_status shares the layout's frontmatter reader ──────────────
# One ledger, one parser. The three answers callers colourise are "-", "null"
# and "?", and the second parser this replaced disagreed with the canvas on the
# last two: a file whose frontmatter is never closed is invisible to the DAG
# (store() only runs on the closing ---) while yq happily reported its status.
echo "--- Test 31: task status parsing ---"
STD="$TMP/statustasks"; mkdir -p "$STD"
printf -- '---\nid: "F83.1"\nstatus: open\nblockers: []\n---\nbody\n'           >| "$STD/F83.1.md"
printf -- '---\nid: "F83.2"\nstatus: "needs-review"\nblockers: []\n---\nbody\n' >| "$STD/F83.2.md"
printf -- '---\nid: "F83.3"\nblockers: []\n---\nbody\n'                        >| "$STD/F83.3.md"
printf -- 'no frontmatter at all\n'                                            >| "$STD/F83.4.md"
printf -- '---\nid: "F83.5"\nstatus: open\n'                                   >| "$STD/F83.5.md"
ts_of() {  # drive task_status through a session row, which is its only caller
    cat >| "$BIN/docker" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    '{{.Names}}|{{.State}}|{{.Status}}') echo 'arachne-agent-t|running|Up 1 minute'; exit 0 ;;
    '{{.Names}}') echo 'arachne-agent-t'; exit 0 ;;
  esac
done
exit 0
EOF
    chmod +x "$BIN/docker"
    local mf="$TMP/ts-manifest.tsv" cache="$TMP/ts-$1.tsv"
    printf 't\tt\tbrief\t%s\n' "$1" >| "$mf"
    TASKPUMP_MANIFEST="$mf" TASKPUMP_TASKS_DIR="$STD" TASKPUMP_MONITOR_SESS_CACHE="$cache" \
        TASKPUMP_MONITOR_REPO_ROOT="$TMP/nowhere" TASKPUMP_MONITOR_COLS=140 "$CLI" >/dev/null 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$cache" ]] && break; sleep 0.3; done
    awk -F'\t' '$1=="S"{print $4; exit}' "$cache" 2>/dev/null
}
[[ "$(ts_of F83.1)" == "open" ]]         && pass "a plain status is read" || fail "plain status: got '$(ts_of F83.1)'"
[[ "$(ts_of F83.2)" == "needs-review" ]] && pass "a quoted status is unquoted" || fail "quoted status: got '$(ts_of F83.2)'"
[[ "$(ts_of F83.3)" == "null" ]]         && pass "a missing status field reads null" || fail "missing field: got '$(ts_of F83.3)'"
[[ "$(ts_of F83.9)" == "-" ]]            && pass "a missing task file reads -" || fail "missing file: got '$(ts_of F83.9)'"
[[ "$(ts_of F83.4)" == "?" ]]            && pass "a file with no frontmatter reads ?" || fail "no frontmatter: got '$(ts_of F83.4)'"
[[ "$(ts_of F83.5)" == "?" ]]            && pass "an unterminated frontmatter block reads ?" || fail "unterminated: got '$(ts_of F83.5)'"
# ...and the canvas agrees: the two unreadable files are absent from the graph,
# which is the disagreement having one parser removes.
gr83=$(TASKPUMP_TASKS_DIR="$STD" "$TP_ROOT/libexec/tp-dag-render" --phases F83 --no-color 2>/dev/null)
grep -q 'F83.4' <<<"$gr83" && fail "the canvas drew a file it cannot parse" \
    || pass "the canvas and the session row agree that F83.4 is unreadable"
printf '#!/usr/bin/env bash\nexit 0\n' >| "$BIN/docker"; chmod +x "$BIN/docker"

# ── Test 32: the legacy ARACHNE_* spellings still drive everything ───────────
# The config core promotes both directions, so an operator's existing exports
# must keep working with no config file in sight. Every assertion above now uses
# the canonical name, so without this the legacy half would be untested.
echo "--- Test 32: legacy env aliases ---"
LEG="$TMP/legacy-notes.md"; printf -- '- 07:00  legacy note body\n' >| "$LEG"
leg=$(env ARACHNE_MONITOR_COLS=60 ARACHNE_MONITOR_NOTES_FILE="$LEG" ARACHNE_MONITOR_DISK=0 \
      "$CLI" 2>/dev/null | strip_ansi)
grep -q 'legacy note body' <<<"$leg" \
    && pass "ARACHNE_MONITOR_NOTES_FILE still selects the notes file" || fail "legacy notes var ignored:\n$leg"
grep -qE '^Notes \[' <<<"$leg" \
    && pass "ARACHNE_MONITOR_COLS still pins the geometry (notes stacked at 60)" || fail "legacy cols var ignored"
# -u because the harness exports the CANONICAL names globally, and canonical
# beating legacy is the documented precedence (asserted just below). Without
# unsetting them there is no legacy-only case left to test.
leggraph=$(env -u TASKPUMP_PUMP_STATE_FILE -u TASKPUMP_TASKS_DIR \
           ARACHNE_PUMP_STATE_FILE="$GPS" ARACHNE_TASKS_DIR="$GTD" ARACHNE_MONITOR_COLS=100 \
           "$CLI" --tab graph 2>/dev/null | strip_ansi)
grep -q '┃ F96.4 ' <<<"$leggraph" \
    && pass "ARACHNE_TASKS_DIR + ARACHNE_PUMP_STATE_FILE still scope the graph" \
    || fail "legacy ledger vars ignored:\n$leggraph"
# Canonical beats legacy when both name a ledger — the documented precedence.
both=$(env -u TASKPUMP_PUMP_STATE_FILE \
       ARACHNE_TASKS_DIR="$TMP/no-such-ledger" TASKPUMP_TASKS_DIR="$GTD" \
       TASKPUMP_PUMP_STATE_FILE="$GPS" TASKPUMP_MONITOR_COLS=100 \
       "$CLI" --tab graph 2>/dev/null | strip_ansi)
grep -q '┃ F96.4 ' <<<"$both" \
    && pass "TASKPUMP_TASKS_DIR outranks ARACHNE_TASKS_DIR" || fail "legacy name won over canonical:\n$both"
# MANIFEST is the one legacy name with no ARACHNE_ prefix, so the config core
# cannot promote it — the monitor has to honour the bare spelling itself.
BM="$TMP/bare-manifest.tsv"; printf 'displayname\tfeat/f97\tbrief.md\tF97.3\n' >| "$BM"
BMC="$TMP/bare-sess.tsv"
cat >| "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    '{{.Names}}|{{.State}}|{{.Status}}') echo 'arachne-agent-feat-f97|running|Up 3 minutes'; exit 0 ;;
    '{{.Names}}') echo 'arachne-agent-feat-f97'; exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$BIN/docker"
bmrun() { env -u TASKPUMP_MANIFEST MANIFEST="$BM" TASKPUMP_TASKS_DIR="$CTD" \
          TASKPUMP_MONITOR_REPO_ROOT="$SFR" TASKPUMP_MONITOR_SESS_CACHE="$BMC" \
          TASKPUMP_MONITOR_COLS=140 "$CLI" 2>/dev/null | strip_ansi; }
bmrun >/dev/null; sleep 2; bm=$(bmrun)
grep -q 'displayname' <<<"$bm" \
    && pass "the bare MANIFEST spelling still supplies the session display name" \
    || fail "bare MANIFEST ignored:\n$bm"
printf '#!/usr/bin/env bash\nexit 0\n' >| "$BIN/docker"; chmod +x "$BIN/docker"

# ── Test 33: the deployment-shaped constants are configurable ───────────────
# The container prefix, the agent log name and the worktree dir were literals in
# six places between them. Renaming them must move the whole session table, not
# half of it — a half-renamed monitor finds containers whose logs it cannot read.
echo "--- Test 33: agent naming is configurable ---"
XR="$TMP/xroot"; mkdir -p "$XR/trees/feat/q"
printf '%s\n' '{"type":"assistant","message":{"content":[{"text":"custom-shaped feed line"}]}}' \
    >| "$XR/trees/feat/q/agent.jsonl"
cat >| "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    '{{.Names}}|{{.State}}|{{.Status}}') echo 'runner-feat-q|running|Up 2 minutes'; exit 0 ;;
    '{{.Names}}') echo 'runner-feat-q'; exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$BIN/docker"
XC="$TMP/x-sess.tsv"
xmon() { TASKPUMP_AGENT_CONTAINER_PREFIX=runner TASKPUMP_AGENT_LOG_NAME=agent.jsonl \
         TASKPUMP_WORKTREES_DIR=trees TASKPUMP_MONITOR_REPO_ROOT="$XR" \
         TASKPUMP_TASKS_DIR="$GTD" TASKPUMP_MONITOR_SESS_CACHE="$XC" \
         TASKPUMP_MONITOR_COLS=140 "$CLI" 2>/dev/null | strip_ansi; }
xmon >/dev/null; sleep 2; xout=$(xmon)
grep -q 'feat-q' <<<"$xout" && pass "a renamed container prefix still yields a session row" \
    || fail "custom container prefix not matched:\n$xout"
grep -q 'custom-shaped feed line' <<<"$xout" \
    && pass "a renamed worktree dir + log name still yield feed lines" \
    || fail "custom log path not resolved:\n$xout"
# The empty-state copy names the configured prefix rather than a fixed one.
printf '#!/usr/bin/env bash\nexit 0\n' >| "$BIN/docker"; chmod +x "$BIN/docker"
empty_x=$(TASKPUMP_AGENT_CONTAINER_PREFIX=runner TASKPUMP_MONITOR_SESS_CACHE="$TMP/x-empty.tsv" \
          TASKPUMP_MONITOR_COLS=100 "$CLI" 2>/dev/null | strip_ansi)
for _ in 1 2 3 4 5; do grep -q 'containers running' <<<"$empty_x" && break
                       sleep 0.5; empty_x=$(TASKPUMP_AGENT_CONTAINER_PREFIX=runner \
                       TASKPUMP_MONITOR_SESS_CACHE="$TMP/x-empty.tsv" TASKPUMP_MONITOR_COLS=100 \
                       "$CLI" 2>/dev/null | strip_ansi); done
grep -q '(no runner containers running or recently exited)' <<<"$empty_x" \
    && pass "the empty-state line names the configured prefix" \
    || fail "empty state still hardcodes a prefix:\n$(grep -i 'containers' <<<"$empty_x")"
# The title is deployment copy, and keeps its historical default.
grep -q '^Arachne Task Pump — ' <<<"$(strip_ansi <<<"$("$CLI" 2>/dev/null)")" \
    && pass "the title keeps its default" || fail "default title changed"
grep -q '^Widget Pipeline — ' <<<"$(TASKPUMP_MONITOR_TITLE='Widget Pipeline' "$CLI" 2>/dev/null | strip_ansi)" \
    && pass "TASKPUMP_MONITOR_TITLE retitles the frame" || fail "title not configurable"

# ── Test 34: the usage gauges are a configured window list ──────────────────
# Two windows were hardcoded, along with the date format each one's reset uses.
echo "--- Test 34: configurable usage windows ---"
make_usage_stub 42 73
uw=$(TASKPUMP_MONITOR_USAGE_WINDOWS='7d=+%a %H:%M' TASKPUMP_MONITOR_COLS=120 "$CLI" 2>/dev/null | strip_ansi)
grep -qE '^[[:space:]]*7d ' <<<"$uw" && pass "a one-window list draws just that window" || fail "7d row missing:\n$uw"
grep -qE '^[[:space:]]*5h ' <<<"$uw" && fail "an unlisted window was drawn anyway:\n$uw" || pass "an unlisted window is not drawn"
# A configured window the payload lacks still gets its row, so the gauge block
# cannot change height under the reader.
uw2=$(TASKPUMP_MONITOR_USAGE_WINDOWS='5h,30d' TASKPUMP_MONITOR_COLS=120 "$CLI" 2>/dev/null | strip_ansi)
grep -qE '^[[:space:]]*30d .*window unavailable' <<<"$uw2" \
    && pass "a window absent from the payload reports itself unavailable" \
    || fail "missing window silently dropped:\n$uw2"
grep -qE '^[[:space:]]*5h .* 42%' <<<"$uw2" && pass "the window that IS present still renders" \
    || fail "5h lost when a sibling was missing:\n$uw2"
# Order follows the config, not the payload.
uw3=$(TASKPUMP_MONITOR_USAGE_WINDOWS='7d,5h' TASKPUMP_MONITOR_COLS=120 "$CLI" 2>/dev/null | strip_ansi)
r7=$(awk '/^[[:space:]]*7d /{print NR; exit}' <<<"$uw3")
r5=$(awk '/^[[:space:]]*5h /{print NR; exit}' <<<"$uw3")
[[ -n "$r7" && -n "$r5" && "$r7" -lt "$r5" ]] && pass "gauge order follows the configured list ($r7 < $r5)" \
    || fail "window order ignored: 7d=$r7 5h=$r5"
# ...and an unreachable meter still draws nothing at all.
make_usage_stub_unreachable
grep -q '▐' <<<"$(TASKPUMP_MONITOR_USAGE_WINDOWS='5h,7d' "$CLI" 2>/dev/null)" \
    && fail "drew a bar with no window data" || pass "an unreachable meter still draws no bars"
make_usage_stub 30 40

# ── Test 35: the GUI spawn argv, and the renderer's absence ─────────────────
# Both were untested and both changed in the port: the terminal's argv is a
# config key now, and the not-found message names the path it looked for. The
# spawn is the one the ARACHNE_MONITOR_OPEN_CMD override BYPASSES, so Test 19
# never reached it — a wrong argv here is invisible until someone presses o on
# a real desktop.
echo "--- Test 35: GUI spawn argv + missing renderer ---"
cat >| "$BIN/faketerm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/argv.txt"
EOF
chmod +x "$BIN/faketerm"
spawn_argv() {  # $@ = extra env assignments → the argv faketerm was handed
    : >| "$TMP/argv.txt"
    env DISPLAY=:0 EDITOR=fake-ed TASKPUMP_MONITOR_TERM=faketerm \
        TASKPUMP_PUMP_STATE_FILE="$GPS" TASKPUMP_TASKS_DIR="$GTD" \
        TASKPUMP_MONITOR_REPO_ROOT="$TMP/spawnrepo" TASKPUMP_MONITOR_COLS=100 \
        "$@" "$CLI" --tab graph --cursor F96.5 --moves o >/dev/null 2>&1
    local i; for i in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$TMP/argv.txt" ]] && break; sleep 0.2; done
    cat "$TMP/argv.txt" 2>/dev/null
}
want="start --always-new-process --class arachne-task --cwd $TMP/spawnrepo -- fake-ed $GTD/F96.5.md"
[[ "$(spawn_argv env)" == "$want" ]] \
    && pass "the default GUI spawn argv is unchanged" \
    || fail "spawn argv drifted:\n  got  $(spawn_argv env)\n  want $want"
# --always-new-process is load-bearing: without it wezterm joins an existing
# instance under the default class, where a windowrule cannot reach the window.
grep -q -- '--always-new-process' <<<"$(spawn_argv env)" \
    && pass "the default argv keeps --always-new-process" || fail "--always-new-process dropped"
# A different terminal is a config change, not a code change.
kitty_want="--app-id mytask --working-directory $TMP/spawnrepo -e fake-ed $GTD/F96.5.md"
got=$(spawn_argv env TASKPUMP_MONITOR_TERM_ARGS='--app-id %CLASS% --working-directory %CWD% -e' \
                     TASKPUMP_MONITOR_TASK_CLASS=mytask)
[[ "$got" == "$kitty_want" ]] \
    && pass "a custom terminal argv expands %CLASS% and %CWD%" \
    || fail "custom argv wrong:\n  got  $got\n  want $kitty_want"

# The renderer's two failure modes both degrade to a line rather than an abort.
gmiss=$(TASKPUMP_DAG_BIN="$TMP/no-such-renderer" TASKPUMP_PUMP_STATE_FILE="$GPS" \
        TASKPUMP_TASKS_DIR="$GTD" TASKPUMP_MONITOR_COLS=100 "$CLI" --tab graph 2>/dev/null | strip_ansi)
grep -q "dag renderer not found: $TMP/no-such-renderer" <<<"$gmiss" \
    && pass "a missing renderer names the path it looked for" || fail "missing-renderer line wrong:\n$gmiss"
grep -q 'SESSIONS' <<<"$gmiss" && pass "...and the rest of the frame still renders" \
    || fail "a missing renderer took the frame down"
printf '#!/usr/bin/env bash\nexit 3\n' >| "$TMP/badrender"; chmod +x "$TMP/badrender"
gfail=$(TASKPUMP_DAG_BIN="$TMP/badrender" TASKPUMP_PUMP_STATE_FILE="$GPS" \
        TASKPUMP_TASKS_DIR="$GTD" TASKPUMP_MONITOR_COLS=100 "$CLI" --tab graph 2>/dev/null | strip_ansi)
grep -q '(dag render failed)' <<<"$gfail" \
    && pass "a failing renderer degrades to one line" || fail "render failure not reported:\n$gfail"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
