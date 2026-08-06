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
PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
TD="$TMP/tasks"; mkdir -p "$TD"
export ARACHNE_TASKS_DIR="$TD"
export ARACHNE_PUMP_STATE_FILE="$TMP/no-such.state"

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

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
