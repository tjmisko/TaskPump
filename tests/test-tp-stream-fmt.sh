#!/usr/bin/env bash
# test-tp-stream-fmt.sh — the agent-log pretty printer, and what it must not let
# through.
#
# `tail -f .taskpump-agent.log | tp stream-fmt` is the command README.md and
# docs/CLI-TOOLS.md tell an operator to watch a drain with, and every field it
# prints was written by somebody else: an agent's narration, a tool call's
# arguments, and — worst — the stdout of a command the agent ran over whatever
# the repository happens to contain. A PR branch from a stranger, a vendored
# dependency, a test golden: land bytes in any of them, wait for the agent to do
# the most ordinary thing in its brief (run the verification command), and the
# bytes are on the supervisor's terminal.
#
# Two halves of the same hole, and this suite pins both:
#
#   1. `echo -e` EXPANDS backslash escapes, so the attacker never even needed a
#      raw ESC byte: a literal `\e[2J` in a fixture survives jq as two harmless
#      characters and becomes a real screen-clear on the way out.
#   2. A raw ESC that does arrive (JSON carries it as a \u001b escape, which jq
#      decodes) was printed verbatim: OSC to rewrite the window title, CUU/EL
#      to walk back over and overwrite the failure lines above.
#
# The assertion is not "no ESC in the output" — the tool colours its own text.
# It is that the ONLY escapes present are the palette's own, and that sanitising
# does not swallow the words: a neutered line still reads.
#
# Run: ./tests/test-tp-stream-fmt.sh   (offline)
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CLI="$TP_ROOT/libexec/tp-stream-fmt"

# Hermeticity: the shared prologue ignores any taskpump.conf in the repo this
# suite happens to run from and scrubs the pump-exported TASKPUMP_*/TP_*/ARACHNE_*
# environment (issue #18). run-all.sh sources the same prologue; this one covers
# standalone runs.
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

[[ -x "$CLI" ]] || { echo "FAIL: tp-stream-fmt not found at $CLI" >&2; exit 1; }

ESC=$'\033'
# The tool's own colours are the seven constants at the top of the file, all of
# the shape ESC [ 0 … m. Strip that shape; an ESC left over is one the tool
# would never have emitted.
strip_palette() { sed -r 's/\x1b\[0[0-9;]*m//g'; }
esc_count() { tr -cd "$ESC" | wc -c | tr -d ' '; }

# ── The fixture ──────────────────────────────────────────────────────────────
# One record per print path, each carrying BOTH payload shapes: a literal
# backslash-e (the `echo -e` amplification) and a real ESC written as a \u001b
# escape (what jq hands back from a hostile JSON string).
STREAM="$WORK/stream.jsonl"
{
  # \\e is a JSON-escaped backslash: the record carries the two characters
  # backslash-e, which only `echo -e` could ever turn into a control byte.
  # \u001b is a JSON unicode escape: jq hands back a real ESC.
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"narration \\e[2J\\e[H\u001b[1;32mFLEET GREEN"}]}}'
  printf '%s\n' '{"type":"tool_use","tool":"Read","input":{"file_path":"/repo/\u001b[8mhidden.txt"}}'
  printf '%s\n' '{"type":"tool_use","tool":"Bash","input":{"command":"make test","description":"run \u001b]0;PWNEDTITLE\u0007 the suite"}}'
  printf '%s\n' '{"type":"tool_result","tool":"Bash","output":"error: real failure here\nline two \u001b[1A\u001b[2K  0 errors, all tests passed"}'
  printf '%s\n' '{"type":"result","result":"done \u001b[5mBLINK","cost_usd":0.5,"num_turns":3}'
  printf '%s\n' 'plain ERROR passthrough \e[2Kforged'
} >| "$STREAM"

# The fixture itself is proof of half the attack: on disk it holds no raw ESC
# at all — the \u001b payloads become ESC only once jq decodes them, and the
# backslash-e ones are inert text unless a printer expands them.
[[ "$(esc_count <"$STREAM")" == "0" ]] \
  && pass "the fixture contains no raw ESC byte at all" \
  || fail "the fixture already holds raw ESC; the amplification case is not being tested"

out=$("$CLI" <"$STREAM" 2>/dev/null)

echo "--- nothing from the stream reaches the terminal as a control sequence ---"

left=$(printf '%s' "$out" | strip_palette | esc_count)
[[ "$left" == "0" ]] \
  && pass "the rendered stream carries no escape the tool did not emit itself" \
  || fail "$left injected ESC bytes reached the terminal:\n$(printf '%s' "$out" | cat -v)"

# Named individually, because a single count can be satisfied by a change that
# drops the line entirely — and each of these is a distinct forgery.
for payload in "${ESC}]0;PWNEDTITLE" "${ESC}[1A" "${ESC}[2K" "${ESC}[2J" "${ESC}[8m" "${ESC}[5m"; do
  if printf '%s' "$out" | grep -qaF "$payload"; then
    fail "a payload survived into the output: $(printf '%s' "$payload" | cat -v)"
  else
    pass "no $(printf '%s' "$payload" | cat -v) in the output"
  fi
done

echo "--- sanitising neuters the bytes, it does not swallow the content ---"

for word in 'narration' 'FLEET GREEN' 'hidden.txt' 'PWNEDTITLE' 'real failure here' \
            '0 errors, all tests passed' 'BLINK' 'forged'; do
  grep -qaF "$word" <<<"$out" \
    && pass "the visible text survives: $word" \
    || fail "sanitising ate content: '$word' is missing from:\n$out"
done

# A Bash result is printed as a TAIL of several lines; sanitising the block
# whole would delete the newlines with the escapes and glue it into one.
[[ "$(grep -caF 'real failure here' <<<"$out")" == "1" ]] \
  && [[ "$(grep -caF '0 errors, all tests passed' <<<"$out")" == "1" ]] \
  && [[ "$(grep -acE 'real failure here.*0 errors' <<<"$out")" == "0" ]] \
  && pass "a multi-line tool result stays multi-line" \
  || fail "the result block was collapsed onto one line:\n$out"

echo "--- the tool still colours its own output ---"

printf '%s' "$out" | grep -qaF "${ESC}[0;34m" \
  && pass "assistant text is still blue" || fail "the blue palette entry is gone"
printf '%s' "$out" | grep -qaF "${ESC}[0;33m" \
  && pass "tool calls are still yellow" || fail "the yellow palette entry is gone"
printf '%s' "$out" | grep -qaF "${ESC}[0;31m" \
  && pass "a failing Bash result is still red" || fail "the red palette entry is gone"
printf '%s' "$out" | grep -qaF "${ESC}[0;32m" \
  && pass "the result block is still green" || fail "the green palette entry is gone"

echo "--- the formatting contract itself is unchanged ---"

grep -qa 'RESULT (3 turns, \$0.5)' <<<"$out" \
  && pass "the result header still names turns and cost" || fail "result header changed:\n$out"
grep -qa '\[Read\] /repo/' <<<"$out" \
  && pass "a Read tool call still shows its path" || fail "Read line missing:\n$out"
grep -qa '\[Bash\] run ' <<<"$out" \
  && pass "a Bash tool call still shows its description" || fail "Bash line missing:\n$out"
# Every other tool_result is dropped, not printed — a quiet run prints nothing.
quiet=$(printf '%s\n' '{"type":"tool_result","tool":"Read","output":"file contents"}' | "$CLI" 2>/dev/null)
[[ -z "$quiet" ]] \
  && pass "a non-Bash tool result is still dropped" || fail "a dropped result printed: '$quiet'"

echo
printf 'Tests: %d  Passed: %d  Failed: %d\n' "$((PASS + FAIL))" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
