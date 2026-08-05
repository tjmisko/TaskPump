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
CLI="$SCRIPT_DIR/arachne-dag-render"
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
for id in .1 .2 .3 .4; do
    grep -qE "│ $id +[^│]*│" <<<"$out" && pass "node $id rendered" || fail "node $id missing:\n$out"
done

# ── Test 2: the ROOT layer is rendered (lay[] subscript regression) ──────────
echo "--- Test 2: root layer present and on top ---"
l1=$(grep -n "│ .1 " <<<"$out" | head -1 | cut -d: -f1)
l2=$(grep -n "│ .2 " <<<"$out" | head -1 | cut -d: -f1)
l4=$(grep -n "│ .4 " <<<"$out" | head -1 | cut -d: -f1)
[[ -n "$l1" && -n "$l2" && "$l1" -lt "$l2" ]] \
    && pass "root .1 renders above its child .2 ($l1 < $l2)" \
    || fail "root layer missing or misordered: .1=$l1 .2=$l2"
[[ -n "$l4" && "$l2" -lt "$l4" ]] \
    && pass "join node .4 renders below its parents ($l2 < $l4)" \
    || fail "join node misordered: .2=$l2 .4=$l4"

# ── Test 3: sibling layer keeps BOTH nodes (cnt[] subscript regression) ──────
echo "--- Test 3: sibling layer complete ---"
sib=$(grep -cE "│ \.2 .*│ \.3 |│ \.3 .*│ \.2 " <<<"$out")
[[ "$sib" -ge 1 ]] && pass ".2 and .3 share one layer row" || fail "siblings not on one row:\n$out"

# ── Test 4: status glyphs ────────────────────────────────────────────────────
echo "--- Test 4: status glyphs ---"
grep -qE "│ \.1 +✓ │" <<<"$out" && pass "done renders ✓" || fail "done glyph wrong"
grep -qE "│ \.3 +⧗ │" <<<"$out" && pass "in_progress with no live agent renders ⧗" || fail "parked glyph wrong"
grep -qE "│ \.4 +◌ │" <<<"$out" && pass "open behind an unfinished blocker renders ◌" || fail "waiting glyph wrong"

# ── Test 5: liveness by task id and by claimed branch ───────────────────────
echo "--- Test 5: liveness ---"
byid=$("$CLI" --phases F90 --no-color --running F90.3 2>/dev/null | strip)
grep -qE "│ \.3 +▶ │" <<<"$byid" && pass "--running marks the task ▶" || fail "--running did not mark ▶"
bybr=$("$CLI" --phases F90 --no-color --live-branches feat/f90 2>/dev/null | strip)
grep -qE "│ \.3 +▶ │" <<<"$bybr" && pass "--live-branches matches claimed_by → ▶" || fail "--live-branches did not mark ▶"

# ── Test 6: eligible vs waiting ─────────────────────────────────────────────
echo "--- Test 6: eligible open task renders ○ ---"
mktask F90.5 F90 open "" F90.2          # only blocker is done → eligible
elig=$("$CLI" --phases F90 --no-color 2>/dev/null | strip)
grep -qE "│ \.5 +○ │" <<<"$elig" && pass "open with all blockers done renders ○" || fail "eligible glyph wrong:\n$elig"
rm -f "$TD/F90.5.md"

# ── Test 7: phase-range scoping ─────────────────────────────────────────────
echo "--- Test 7: phase scope ---"
grep -q 'F91' <<<"$out" && fail "out-of-range phase leaked into the graph" || pass "F91 excluded from an F90 graph"
rng=$("$CLI" --phases F90..F91 --no-color 2>/dev/null | strip)
grep -q 'F91.1' <<<"$rng" && pass "F90..F91 range includes F91" || fail "range scope missed F91:\n$rng"
grep -q 'F90.1' <<<"$rng" && pass "a multi-phase range uses full ids" || fail "multi-phase range should not compact ids"

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

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
