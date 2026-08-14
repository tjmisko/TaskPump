#!/usr/bin/env bash
# test-arachne-dag-render.sh — fixture-driven tests for the layered task-DAG
# renderer. Builds a synthetic tasks dir so layering, ordering, status glyphs
# and the phase-range scope are all deterministic.
#
# Several cases here are regression guards for the awk uninitialised-subscript
# trap: a counter or conditionally-assigned array used as a subscript
# stringifies to "" and silently drops elements. That bug class made the root
# layer and the last node of every layer disappear — output that still looked
# like a plausible graph, which is exactly why it needs explicit assertions.
#
# Run: ./scripts/test-arachne-dag-render.sh  (exits non-zero on any failure)
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CLI="$TP_ROOT/libexec/tp-dag-render"

# Hermeticity: the shared prologue ignores any taskpump.conf in the repo this
# suite happens to run from (a leaked conf reconfigures every fixture
# invocation below) and scrubs the pump-exported TASKPUMP_*/TP_*/ARACHNE_*
# environment (issue #18). run-all.sh sources the same prologue; this one
# covers standalone runs.
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
TD="$TMP/tasks"; mkdir -p "$TD"
export TASKPUMP_TASKS_DIR="$TD"
export TASKPUMP_PUMP_STATE_FILE="$TMP/no-such.state"

# Reference pin (G1.2): the fixtures below are F-grammar and the --phases
# ranges parse through the sigil, whose baked default flips to T in G1.6.
# Pinned with the examples/arachne.conf value.
export TASKPUMP_PHASE_SIGIL=F

# mktask <id> <phase> <status> <claimed_by> [blocker ...]
mktask() {
    local id="$1" ph="$2" st="$3" by="$4"; shift 4
    {
        echo '---'
        echo "id: \"$id\""
        echo "phase: \"$ph\""
        echo "status: $st"
        echo "claimed_by: $by"
        if (( $# )); then
            echo 'blockers:'
            for b in "$@"; do echo "  - \"$b\""; done
        else
            echo 'blockers: []'
        fi
        echo '---'
        echo 'body'
    } >| "$TD/$id.md"
}

#   F90.1 ──┬── F90.2 ──┬── F90.4
#           └── F90.3 ──┘
mktask F90.1 F90 done         ""
mktask F90.2 F90 done         ""        F90.1
mktask F90.3 F90 in_progress  feat/f90  F90.1
mktask F90.4 F90 open         ""        F90.2 F90.3
# a second phase, to prove range scoping excludes it
mktask F91.1 F91 open         ""

strip() { sed -r 's/\x1b\[[0-9;]*m//g'; }

# ── Test 1: every node is rendered (node-drop regression) ────────────────────
echo "--- Test 1: all nodes present ---"
out=$("$CLI" --phases F90 --no-color 2>/dev/null | strip)
for id in F90.1 F90.2 F90.3 F90.4; do
    grep -qE "│ $id +[^│]*│" <<<"$out" && pass "node $id rendered" || fail "node $id missing:\n$out"
done

# ── Test 2: the ROOT layer is rendered (lay[] subscript regression) ──────────
echo "--- Test 2: root layer present and on top ---"
l1=$(grep -n "│ F90.1 " <<<"$out" | head -1 | cut -d: -f1)
l2=$(grep -n "│ F90.2 " <<<"$out" | head -1 | cut -d: -f1)
l4=$(grep -n "│ F90.4 " <<<"$out" | head -1 | cut -d: -f1)
[[ -n "$l1" && -n "$l2" && "$l1" -lt "$l2" ]] \
    && pass "root F90.1 renders above its child F90.2 ($l1 < $l2)" \
    || fail "root layer missing or misordered: F90.1=$l1 F90.2=$l2"
[[ -n "$l4" && "$l2" -lt "$l4" ]] \
    && pass "join node F90.4 renders below its parents ($l2 < $l4)" \
    || fail "join node misordered: F90.2=$l2 F90.4=$l4"

# ── Test 3: sibling layer keeps BOTH nodes (cnt[] subscript regression) ──────
echo "--- Test 3: sibling layer complete ---"
sib=$(grep -cE "│ F90\.2 .*│ F90\.3 |│ F90\.3 .*│ F90\.2 " <<<"$out")
[[ "$sib" -ge 1 ]] && pass "F90.2 and F90.3 share one layer row" || fail "siblings not on one row:\n$out"

# ── Test 4: status glyphs ────────────────────────────────────────────────────
echo "--- Test 4: status glyphs ---"
grep -qE "│ F90\.1 +✓ │" <<<"$out" && pass "done renders ✓" || fail "done glyph wrong"
grep -qE "│ F90\.3 +⧗ │" <<<"$out" && pass "in_progress with no live agent renders ⧗" || fail "parked glyph wrong"
grep -qE "│ F90\.4 +◌ │" <<<"$out" && pass "open behind an unfinished blocker renders ◌" || fail "waiting glyph wrong"

# ── Test 5: liveness by task id and by claimed branch ───────────────────────
echo "--- Test 5: liveness ---"
byid=$("$CLI" --phases F90 --no-color --running F90.3 2>/dev/null | strip)
grep -qE "│ F90\.3 +▶ │" <<<"$byid" && pass "--running marks the task ▶" || fail "--running did not mark ▶"
bybr=$("$CLI" --phases F90 --no-color --live-branches feat/f90 2>/dev/null | strip)
grep -qE "│ F90\.3 +▶ │" <<<"$bybr" && pass "--live-branches matches claimed_by → ▶" || fail "--live-branches did not mark ▶"

# ── Test 6: eligible vs waiting ─────────────────────────────────────────────
echo "--- Test 6: eligible open task renders ○ ---"
mktask F90.5 F90 open "" F90.2          # only blocker is done → eligible
elig=$("$CLI" --phases F90 --no-color 2>/dev/null | strip)
grep -qE "│ F90\.5 +○ │" <<<"$elig" && pass "open with all blockers done renders ○" || fail "eligible glyph wrong:\n$elig"
rm -f "$TD/F90.5.md"

# ── Test 7: phase-range scoping ─────────────────────────────────────────────
echo "--- Test 7: phase scope ---"
grep -q 'F91' <<<"$out" && fail "out-of-range phase leaked into the graph" || pass "F91 excluded from an F90 graph"
rng=$("$CLI" --phases F90..F91 --no-color 2>/dev/null | strip)
grep -q 'F91.1' <<<"$rng" && pass "F90..F91 range includes F91" || fail "range scope missed F91:\n$rng"
grep -q 'F90.1' <<<"$rng" && pass "a multi-phase range uses full ids" || fail "multi-phase range should not compact ids"
# A single-phase range keeps the phase too: `.17` is not something you can paste
# into arachne-task or match against the pump's log.
grep -qE "│ F90\.1 " <<<"$out" && pass "a single-phase range also uses full ids" \
    || fail "single-phase range dropped the phase prefix"
short=$("$CLI" --phases F90 --no-color --compact 2>/dev/null | strip)
grep -qE "│ \.1 " <<<"$short" && pass "--compact still shortens the label" \
    || fail "--compact no longer drops the phase prefix:\n$short"

# ── Test 8: box drawing + edges ─────────────────────────────────────────────
echo "--- Test 8: structure glyphs ---"
grep -q '┌' <<<"$out" && grep -q '└' <<<"$out" && pass "boxes drawn" || fail "no box borders"
grep -q '┬' <<<"$out" && pass "edges leave a parent (┬)" || fail "no outgoing port"
grep -q '┴' <<<"$out" && pass "edges enter a child (┴)" || fail "no incoming port"

# ── Test 9: colour control ──────────────────────────────────────────────────
echo "--- Test 9: colour ---"
"$CLI" --phases F90 --no-color 2>/dev/null | grep -q $'\033\[' \
    && fail "--no-color still emitted escapes" || pass "--no-color emits no ANSI"
"$CLI" --phases F90 2>/dev/null | grep -q $'\033\[' \
    && pass "colour mode emits ANSI" || fail "colour mode emitted none"

# The status palette: green is the progress axis. done is a dimmed faded green,
# a task with a live agent is a calmer mid green, an unstarted one is grey.
col=$("$CLI" --phases F90 --live-branches feat/f90 2>/dev/null)
grep -q $'\033\[0;2;38;5;65m' <<<"$col" && pass "done wears dark faded green" || fail "no faded green for done"
grep -q $'\033\[0;38;5;71m'   <<<"$col" && pass "a live task wears mid green" || fail "no mid green for the live task"
grep -q $'\033\[0;2;38;5;244m' <<<"$col" && pass "an open task waiting on a blocker wears dim grey" \
    || fail "no dim grey for the waiting task"
# F91.1 is open with no blockers, so it is the ready (brighter grey) case.
"$CLI" --phases F90..F91 2>/dev/null | grep -q $'\033\[0;38;5;250m' \
    && pass "a ready task wears grey" || fail "no grey for the ready task"
# Without a live container the same in_progress task is parked, not running.
"$CLI" --phases F90 2>/dev/null | grep -q $'\033\[0;38;5;71m' \
    && fail "the running colour used for a task with no live agent" \
    || pass "a claimed-but-dead task is not painted running"

# Edge tiers: a component whose endpoints are all done wears the done green, so
# a finished subtree reads as one settled unit; anything touching unfinished
# work stays on the bright rail. Both must remain legible.
grep -q $'\033\[0;38;5;249m' <<<"$col" && pass "live-frontier edges use the bright rail" \
    || fail "no bright rail colour"
# F90 has no fully-done edge component — every band there touches F90.3/F90.4 —
# so the green-edge case needs its own chain: F98.1 → F98.2, both done.
mktask F98.1 F98 done ""
mktask F98.2 F98 done ""  F98.1
# A colour run reaches to the next escape, so the whole run is what carries the
# ink; the sequence itself opens on blanks. Node boxes cannot match here: done
# NODES carry the dimmed 0;2;38;5;65, a different sequence.
greenrail=$("$CLI" --phases F98 2>/dev/null \
            | grep -o $'\033\[0;38;5;65m[^\033]*' | grep -c '[─│┬┴├┤┼┌┐└┘]' || true)
[[ "${greenrail:-0}" -ge 1 ]] \
    && pass "a done→done edge is drawn in the done green ($greenrail runs)" \
    || fail "no green edge ink for a fully-done component"
# ...and the same edge is not green once its child is unfinished.
mktask F98.2 F98 open ""  F98.1
notgreen=$("$CLI" --phases F98 2>/dev/null \
           | grep -o $'\033\[0;38;5;65m[^\033]*' | grep -c '[─│┬┴├┤┼┌┐└┘]' || true)
[[ "${notgreen:-0}" -eq 0 ]] \
    && pass "an edge into unfinished work stays on the bright rail" \
    || fail "green edge ink survived the child becoming open ($notgreen runs)"
# Dimming is per EDGE, not per rail component: one parent with a done child and
# an open child shares a band, and the settled link must still be green. At
# component granularity the open child dragged the whole band bright — which is
# what kept F79.1 → F79.2 grey while both were done.
mktask F98.2 F98 done ""  F98.1
mktask F98.3 F98 open ""  F98.1
mixed=$("$CLI" --phases F98 2>/dev/null)
[[ "$(grep -o $'\033\[0;38;5;65m[^\033]*' <<<"$mixed" | grep -c '[─│┬┴├┤┼┌┐└┘]' || true)" -ge 1 ]] \
    && pass "a done link stays green in a band shared with an unfinished one" \
    || fail "per-edge dimming lost: the shared band is entirely bright"
[[ "$(grep -o $'\033\[0;38;5;249m[^\033]*' <<<"$mixed" | grep -c '[─│┬┴├┤┼┌┐└┘]' || true)" -ge 1 ]] \
    && pass "...and the unfinished link in that same band stays bright" \
    || fail "the open child's link is not on the bright rail"
rm -f "$TD"/F98.*.md

# Attribute leak: SGR dim/bold are sticky, so every sequence must re-open with
# 0. A single non-absolute one after a dim `done` box greys out the whole rest
# of the row -- which is what made the graph look uniformly grey.
leaky=$("$CLI" --phases F90 --live-branches feat/f90 2>/dev/null \
        | grep -oE $'\033\\[[0-9;]*m' | grep -vE $'\033\\[0(;|m)' || true)
[[ -z "$leaky" ]] && pass "every colour sequence is absolute (re-opens with 0)" \
    || fail "non-absolute sequences leak attributes: $(tr -d '\033' <<<"$leaky" | sort -u | tr '\n' ' ')"

# ── Test 10: panning + empty range ──────────────────────────────────────────
echo "--- Test 10: pan and empty range ---"
p0=$("$CLI" --phases F90 --no-color 2>/dev/null | strip | sed -n '1p')
p4=$("$CLI" --phases F90 --no-color --pan 4 2>/dev/null | strip | sed -n '1p')
[[ "$p0" != "$p4" && -n "$p4" ]] && pass "--pan shifts the canvas" || fail "--pan had no effect"
empty=$("$CLI" --phases F99 --no-color 2>/dev/null | strip)
grep -q 'no tasks in range' <<<"$empty" && pass "empty range reports cleanly" || fail "empty range output: $empty"

# ── Test 11: arg handling ───────────────────────────────────────────────────
echo "--- Test 11: args ---"
"$CLI" --bogus >/dev/null 2>&1; rc=$?
[[ "$rc" -ne 0 ]] && pass "unknown arg exits non-zero" || fail "unknown arg accepted"
"$CLI" --help >/dev/null 2>&1 && pass "--help exits 0" || fail "--help failed"

# ── Test 12: I2 — a multi-layer edge is actually drawn ──────────────────────
# The exact bug v1 shipped: the router only joined layer L to L+1, so an edge
# spanning further was silently dropped and the graph under-reported the DAG.
# F92.5 is a root whose ONLY relationship is the 3-layer edge into F92.4, so if
# that edge is missing it has no bottom port at all — the 2026-08-05 screenshot.
echo "--- Test 12: multi-layer edges (I2) ---"
mktask F92.1 F92 done ""
mktask F92.2 F92 done ""        F92.1
mktask F92.3 F92 done ""        F92.2
mktask F92.5 F92 done ""
mktask F92.4 F92 open ""        F92.3 F92.5
IDX="$TMP/idx.tsv"
span=$("$CLI" --phases F92 --no-color --index-file "$IDX" 2>/dev/null | strip)
# The source box's bottom border must carry an outgoing port.
srcport=$(awk '/│ F92\.5 /{getline; print; exit}' <<<"$span")
grep -q '┬' <<<"$srcport" && pass "the far source F92.5 has a bottom port" \
    || fail "multi-layer edge dropped at the source (bottom border: '$srcport')"
tgtport=$(awk '/│ F92\.4 /{print prev; exit} {prev=$0}' <<<"$span")
grep -q '┴' <<<"$tgtport" && pass "the far target F92.4 has a top port" \
    || fail "multi-layer edge dropped at the target (top border: '$tgtport')"
# ...and the trunk between them is one unbroken column (O2 for inner segments):
# every row from under .5's box to above .4's box has ink in .5's port column.
cx5=$(awk -F'\t' '$1=="F92.5"{print $4}' "$IDX")
y5=$(awk -F'\t' '$1=="F92.5"{print $5}' "$IDX")
y4=$(awk -F'\t' '$1=="F92.4"{print $5}' "$IDX")
trunk=$(awk -v col="$cx5" -v lo="$((y5 + 3))" -v hi="$((y4 - 1))" '
    NR - 1 >= lo && NR - 1 <= hi && substr($0, col + 1, 1) == " " { bad++ }
    END { print bad + 0 }' <<<"$span")
[[ -n "$cx5" && "$trunk" == "0" ]] && pass "the dummy trunk is a straight unbroken column" \
    || fail "trunk column $cx5 broken in $trunk row(s) of $lo..$hi:\n$span"
rm -f "$TD"/F92.*.md

# ── Test 13: O2 — a single child sits directly under its parent ─────────────
echo "--- Test 13: straightness (O2) ---"
mktask F93.1 F93 done ""
mktask F93.2 F93 open "" F93.1
"$CLI" --phases F93 --no-color --index-file "$IDX" >/dev/null 2>&1
cx1=$(awk -F'\t' '$1=="F93.1"{print $4}' "$IDX")
cx2=$(awk -F'\t' '$1=="F93.2"{print $4}' "$IDX")
[[ -n "$cx1" && "$cx1" == "$cx2" ]] \
    && pass "an only child is x-aligned with its parent ($cx1)" \
    || fail "single-child edge not vertical: parent=$cx1 child=$cx2"
rm -f "$TD"/F93.*.md

# ── Test 14: O3 — unrelated neighbours get a wider gutter than siblings ─────
echo "--- Test 14: subtree separation (O3) ---"
mktask F94.1 F94 done ""
mktask F94.2 F94 done ""
mktask F94.3 F94 done "" F94.1
mktask F94.4 F94 done "" F94.1
mktask F94.5 F94 done "" F94.2
"$CLI" --phases F94 --no-color --index-file "$IDX" >/dev/null 2>&1
g34=$(awk -F'\t' '$1=="F94.3"{a=$4} $1=="F94.4"{b=$4} END{d=b-a; print (d<0?-d:d)}' "$IDX")
g45=$(awk -F'\t' '$1=="F94.4"{a=$4} $1=="F94.5"{b=$4} END{d=b-a; print (d<0?-d:d)}' "$IDX")
[[ -n "$g34" && -n "$g45" && "$g45" -gt "$g34" ]] \
    && pass "unrelated neighbours sit further apart than siblings ($g45 > $g34)" \
    || fail "no subtree gutter: sibling gap=$g34 unrelated gap=$g45"
rm -f "$TD"/F94.*.md

# ── Test 15: O1 — ordering removes an avoidable crossing ────────────────────
# Read in file order the layer-1 nodes start crossed (.3 hangs off .2, .4 off
# .1). A working crossing-reduction pass swaps them, leaving no ┼ at all.
echo "--- Test 15: crossing reduction (O1) ---"
mktask F95.1 F95 done ""
mktask F95.2 F95 done ""
mktask F95.3 F95 done "" F95.2
mktask F95.4 F95 done "" F95.1
cross=$("$CLI" --phases F95 --no-color 2>/dev/null | strip | grep -c '┼' || true)
[[ "$cross" == "0" ]] && pass "an avoidable crossing is ordered away" \
    || fail "expected 0 crossings, drew $cross"
rm -f "$TD"/F95.*.md

# ── Test 16: determinism ────────────────────────────────────────────────────
echo "--- Test 16: determinism (I6) ---"
d1=$("$CLI" --phases F90 --no-color 2>/dev/null | md5sum)
d2=$("$CLI" --phases F90 --no-color 2>/dev/null | md5sum)
[[ "$d1" == "$d2" ]] && pass "two runs are byte-identical" || fail "render is not deterministic"

# ── Test 17: cursor + index table ───────────────────────────────────────────
echo "--- Test 17: cursor and index ---"
cur=$("$CLI" --phases F90 --no-color --cursor F90.3 --index-file "$IDX" 2>/dev/null | strip)
grep -q '┃ F90.3 ' <<<"$cur" && pass "--cursor draws a heavy border" || fail "no heavy border:\n$cur"
grep -q '│ F90.1 ' <<<"$cur" && pass "unselected nodes keep a light border" || fail "light border lost"
n_idx=$(wc -l < "$IDX")
[[ "$n_idx" == "4" ]] && pass "index has one row per in-scope task (4)" || fail "index rows: $n_idx"
awk -F'\t' '$1=="F90.4" && $2==2 && $10=="F90.2:done|F90.3:in_progress"' "$IDX" | grep -q . \
    && pass "index carries layer and blocker statuses" \
    || fail "index row wrong: $(grep F90.4 "$IDX")"
awk -F'\t' '$1=="F90.3" && $7=="feat/f90"' "$IDX" | grep -q . \
    && pass "index carries the claimed branch" || fail "claimed_by missing from index"

# ── Test 18: viewport clipping ──────────────────────────────────────────────
echo "--- Test 18: --cols clips the viewport ---"
wide=$("$CLI" --phases F90 --no-color 2>/dev/null | strip | awk '{ if (length($0) > m) m = length($0) } END { print m }')
clip=$("$CLI" --phases F90 --no-color --cols 12 2>/dev/null | strip | awk '{ if (length($0) > m) m = length($0) } END { print m }')
[[ "$clip" -le 12 && "$wide" -gt "$clip" ]] \
    && pass "--cols clips long lines ($wide → $clip)" || fail "--cols did not clip: $wide vs $clip"

# ── Test 19: the alarm statuses ─────────────────────────────────────────────
# blocked / needs-review / stuck had NO fixture in either suite: three of the
# six statuses the ledger can hold were drawn by code nothing exercised. They
# are also the three a reader most needs to see, so a silent regression here
# would hide exactly the tasks that need a human.
echo "--- Test 19: blocked / needs-review / stuck ---"
mktask F86.1 F86 done         ""
mktask F86.2 F86 blocked      ""  F86.1
mktask F86.3 F86 needs-review ""  F86.1
mktask F86.4 F86 stuck        ""  F86.1
alarm=$("$CLI" --phases F86 --no-color 2>/dev/null | strip)
grep -qE "│ F86\.2 +⊘ │" <<<"$alarm" && pass "blocked renders ⊘" || fail "blocked glyph wrong:\n$alarm"
grep -qE "│ F86\.3 +! │" <<<"$alarm" && pass "needs-review renders !" || fail "needs-review glyph wrong:\n$alarm"
grep -qE "│ F86\.4 +! │" <<<"$alarm" && pass "stuck renders !" || fail "stuck glyph wrong:\n$alarm"
# ...and their hues, which are the STATE palette's ⊘ muted red and ! coral. R5:
# hue() here and the ST_* constants in tp-monitor are one vocabulary in two
# languages, so a change to either alone is the bug this pins.
alarmc=$("$CLI" --phases F86 2>/dev/null)
grep -q $'\033\[0;38;5;131m' <<<"$alarmc" && pass "blocked wears the muted red" \
    || fail "no muted red for blocked"
grep -q $'\033\[0;1;38;5;203m' <<<"$alarmc" && pass "needs-review / stuck wear the alert coral" \
    || fail "no coral for the review statuses"
# Every sequence still absolute, on the statuses that were never rendered before.
leaky19=$(printf '%s' "$alarmc" | grep -oE $'\033\\[[0-9;]*m' | grep -vE $'\033\\[0(;|m)' || true)
[[ -z "$leaky19" ]] && pass "the alarm statuses emit no attribute-leaking sequence" \
    || fail "non-absolute sequence in an alarm hue: $(tr -d '\033' <<<"$leaky19" | sort -u | tr '\n' ' ')"
rm -f "$TD"/F86.*.md

# ── Test 20: --full-ids ─────────────────────────────────────────────────────
# Full ids are the default in every range, so --full-ids only does visible work
# when it OVERRIDES a --compact earlier on the same line. That is the whole
# reason the flag exists, and it had no test at all.
echo "--- Test 20: --full-ids ---"
full=$("$CLI" --phases F90 --no-color --full-ids 2>/dev/null | strip)
grep -qE "│ F90\.1 " <<<"$full" && pass "--full-ids keeps the phase prefix" \
    || fail "--full-ids dropped the phase:\n$full"
over=$("$CLI" --phases F90 --no-color --compact --full-ids 2>/dev/null | strip)
grep -qE "│ F90\.1 " <<<"$over" && pass "--full-ids after --compact wins (last flag wins)" \
    || fail "--full-ids did not override --compact:\n$over"
rev=$("$CLI" --phases F90 --no-color --full-ids --compact 2>/dev/null | strip)
grep -qE "│ \.1 " <<<"$rev" && pass "--compact after --full-ids wins too" \
    || fail "flag order not honoured in reverse:\n$rev"

# ── Test 21: out-of-range blockers enter as stub nodes ──────────────────────
# select() pulls an out-of-range blocker in when it is UNFINISHED, so the reader
# can see what the range is waiting on; a done one is history and would just
# widen the graph. Neither half had a fixture.
echo "--- Test 21: out-of-range blocker stubs ---"
mktask F87.9 F87 open  ""              # out of range, unfinished → pulled in
mktask F88.9 F88 done  ""              # out of range, finished  → left out
mktask F89.1 F89 open  ""  F87.9
mktask F89.2 F89 open  ""  F88.9
stub=$("$CLI" --phases F89 --no-color 2>/dev/null | strip)
grep -qE "│ F87\.9 " <<<"$stub" && pass "an unfinished out-of-range blocker is drawn as a stub" \
    || fail "out-of-range blocker missing:\n$stub"
grep -q 'F88.9' <<<"$stub" && fail "a DONE out-of-range blocker widened the graph:\n$stub" \
    || pass "a done out-of-range blocker is left out"
# The stub is a real node with a real edge, not a floating box: its dependent
# must sit strictly below it (I3).
sy=$(grep -n "│ F87.9 " <<<"$stub" | head -1 | cut -d: -f1)
dy=$(grep -n "│ F89.1 " <<<"$stub" | head -1 | cut -d: -f1)
[[ -n "$sy" && -n "$dy" && "$sy" -lt "$dy" ]] \
    && pass "the stub layers above its in-range dependent ($sy < $dy)" \
    || fail "stub not layered above its dependent: stub=$sy dep=$dy"
# ...and the dependent is WAITING on it, which is the point of pulling it in.
grep -qE "│ F89\.1 +◌ │" <<<"$stub" && pass "the dependent reads ◌ waiting behind the stub" \
    || fail "dependent not waiting:\n$stub"
rm -f "$TD"/F87.*.md "$TD"/F88.*.md "$TD"/F89.*.md

# ── Test 22: mglyph's junction cases (├ ┤ ┼) ────────────────────────────────
# The bitmask rewrite exists BECAUSE merging glyphs incrementally drew a column
# of ┬ stubs where a trunk collected several parents. Until now ┼ was only ever
# asserted ABSENT (Test 15) and ├ / ┤ never appeared in a fixture at all — the
# glyphs that motivated the rewrite had no positive test.
#
# Two mirrored fan-in trunks: each of .5 and .6 depends on the whole chain, so
# one trunk runs down each side of it and the chain's parents join one from the
# left (┤) and one from the right (├), crossing the other trunk's rails (┼).
echo "--- Test 22: junction glyphs ---"
mktask F82.1 F82 done ""
mktask F82.2 F82 done ""  F82.1
mktask F82.3 F82 done ""  F82.2
mktask F82.4 F82 done ""  F82.3
mktask F82.5 F82 open ""  F82.1 F82.2 F82.3 F82.4
mktask F82.6 F82 open ""  F82.1 F82.2 F82.3 F82.4
junc=$("$CLI" --phases F82 --no-color 2>/dev/null | strip)
for pair in '├:a trunk joined from the right' '┤:a trunk joined from the left' '┼:a genuine crossing'; do
    gl="${pair%%:*}"; what="${pair#*:}"
    n=$(grep -o "$gl" <<<"$junc" | wc -l)
    [[ "$n" -ge 1 ]] && pass "$gl renders for $what ($n)" || fail "$gl never drawn:\n$junc"
done
# The failure mode this replaced: merging glyphs incrementally cannot express
# "a vertical passes THROUGH a join", so a trunk collecting four parents drew
# four disconnected ┬ stubs. The property that fixes is exactly this — every
# junction cell has ink directly above AND below it, because the vertical it
# sits on continues past the join. (A ┬ on a rail row is legal and expected: it
# is mask 14, an edge fanning downward, which is a different cell entirely.)
broken=$(awk '
    { row[NR] = $0 }
    END {
        for (y = 1; y <= NR; y++) {
            n = split(row[y], ch, "")
            for (x = 1; x <= n; x++) {
                if (ch[x] != "├" && ch[x] != "┤" && ch[x] != "┼") continue
                split(row[y-1], up, ""); split(row[y+1], dn, "")
                a = (y > 1)  ? up[x] : ""
                b = (y < NR) ? dn[x] : ""
                if (a == "" || a == " " || b == "" || b == " ")
                    printf "row %d col %d: %s above=[%s] below=[%s]\n", y, x, ch[x], a, b
            }
        }
    }' <<<"$junc")
[[ -z "$broken" ]] && pass "every junction cell carries the vertical through it" \
    || fail "a junction is not on a continuous vertical:\n$broken\n$junc"
rm -f "$TD"/F82.*.md

# ── Test 23: the ledger-shaped early exits ──────────────────────────────────
# Both are exit-0 paths, so a caller that lost them would render an empty frame
# and look merely idle rather than misconfigured.
echo "--- Test 23: missing / empty ledger ---"
nodir=$(TASKPUMP_TASKS_DIR="$TMP/no-such-ledger" "$CLI" --phases F90 2>/dev/null); rc=$?
grep -q "no tasks dir: $TMP/no-such-ledger" <<<"$nodir" && [[ "$rc" -eq 0 ]] \
    && pass "a missing tasks dir names the path it looked for, exit 0" \
    || fail "missing-dir message wrong (rc=$rc): $nodir"
mkdir -p "$TMP/empty-ledger"
notasks=$(TASKPUMP_TASKS_DIR="$TMP/empty-ledger" "$CLI" --phases F90 2>/dev/null); rc=$?
[[ "$notasks" == "(no tasks found)" && "$rc" -eq 0 ]] \
    && pass "an empty tasks dir reports cleanly, exit 0" \
    || fail "empty-dir message wrong (rc=$rc): $notasks"

# ── Test 24: --claims edge cases ────────────────────────────────────────────
# The SESSIONS tab reads this. A branch with no claim must produce no row (not
# an empty one), and a claim with no turn budget must say so in a way the
# monitor's `!= null` test can act on.
echo "--- Test 24: --claims edges ---"
# A ledger with tasks but no in_progress claim. (An EMPTY dir takes the
# "(no tasks found)" early exit instead, which Test 23 covers.)
UNCLAIMED="$TMP/unclaimed"; mkdir -p "$UNCLAIMED"
printf -- '---\nid: "F84.1"\nphase: "F84"\nstatus: open\nclaimed_by: ""\nblockers: []\n---\nbody\n' \
    >| "$UNCLAIMED/F84.1.md"
noclaim=$(TASKPUMP_TASKS_DIR="$UNCLAIMED" "$CLI" --claims 2>/dev/null)
[[ -z "$noclaim" ]] && pass "a ledger with no claims emits no rows" || fail "spurious claim rows: $noclaim"
# F90.3 is in_progress on feat/f90 and was made without a turn_budget_remaining.
cl24=$("$CLI" --claims 2>/dev/null)
[[ "$(awk -F'\t' '$1=="feat/f90"{print NF}' <<<"$cl24")" == "4" ]] \
    && pass "a claim row has all four fields" || fail "claim row is not 4 fields: $cl24"
[[ "$(awk -F'\t' '$1=="feat/f90"{print $3}' <<<"$cl24")" == "null" ]] \
    && pass "an absent turn budget renders the literal null" \
    || fail "turn budget not null: $(awk -F'\t' '$1=="feat/f90"' <<<"$cl24")"
# Only in_progress claims count — a done task's branch is not holding anything.
mktask F85.1 F85 done "feat/f85"
[[ -z "$("$CLI" --claims 2>/dev/null | awk -F'\t' '$1=="feat/f85"')" ]] \
    && pass "a done task's branch holds no claim" || fail "a done task produced a claim row"
rm -f "$TD"/F85.*.md

# ── Test 25: the interpreter is named when it is wrong ──────────────────────
# and()/or() are gawk extensions; mawk would mis-render every junction rather
# than stopping. The check must name the dependency, not fail obscurely.
echo "--- Test 25: gawk requirement ---"
notgawk=$(TASKPUMP_AWK=/nonexistent-awk "$CLI" --phases F90 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && grep -q 'gawk' <<<"$notgawk" \
    && pass "a missing awk fails loudly and names gawk" \
    || fail "missing awk not reported clearly (rc=$rc): $notgawk"
cat >| "$TMP/fake-awk" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/fake-awk"
badawk=$(TASKPUMP_AWK="$TMP/fake-awk" "$CLI" --phases F90 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && grep -q 'GNU awk' <<<"$badawk" \
    && pass "a non-GNU awk is rejected before anything is drawn" \
    || fail "non-gawk not rejected (rc=$rc): $badawk"

# ── Test 26: the id grammar is configurable ─────────────────────────────────
# Phase = <sigil><digits> up to the separator. Both halves are hooks now, and a
# sigil is a literal prefix rather than a pattern.
echo "--- Test 26: configurable id grammar ---"
PTD="$TMP/ptasks"; mkdir -p "$PTD"
pmk() {  # <id> <status> [blocker ...]
    local id="$1" st="$2"; shift 2
    { echo '---'; echo "id: \"$id\""; echo "status: $st"; echo 'claimed_by: ""'
      if (( $# )); then echo 'blockers:'; for b in "$@"; do echo "  - \"$b\""; done
      else echo 'blockers: []'; fi
      echo '---'; echo body; } >| "$PTD/$id.md"
}
pmk P12-1 done; pmk P12-2 open P12-1; pmk P13-1 open
pg=$(TASKPUMP_TASKS_DIR="$PTD" TASKPUMP_PHASE_SIGIL=P TASKPUMP_PHASE_SEPARATOR=- \
     "$CLI" --phases P12 --no-color 2>/dev/null | strip)
grep -qE "│ P12-1 +✓ │" <<<"$pg" && pass "a P<n>-<m> id grammar layers and draws" \
    || fail "custom grammar did not render:\n$pg"
grep -q 'P13-1' <<<"$pg" && fail "the P13 phase leaked into a P12 graph:\n$pg" \
    || pass "phase scoping honours the configured sigil"
pc=$(TASKPUMP_TASKS_DIR="$PTD" TASKPUMP_PHASE_SIGIL=P TASKPUMP_PHASE_SEPARATOR=- \
     "$CLI" --phases P12 --no-color --compact 2>/dev/null | strip)
grep -qE "│ -1 " <<<"$pc" && pass "--compact shortens at the configured separator" \
    || fail "--compact used the wrong separator:\n$pc"
prng=$(TASKPUMP_TASKS_DIR="$PTD" TASKPUMP_PHASE_SIGIL=P TASKPUMP_PHASE_SEPARATOR=- \
       "$CLI" --phases P12..P13 --no-color 2>/dev/null | strip)
grep -q 'P13-1' <<<"$prng" && pass "A..B ranges work on the configured sigil" \
    || fail "range scoping missed P13:\n$prng"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
