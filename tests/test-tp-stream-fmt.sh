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

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
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
# The tool's own colours, read out of the tool's own source rather than matched
# by shape. Stripping the SHAPE (ESC [ 0 … m) would also swallow an injected
# `ESC[0;5m` blink or `ESC[0;30;40m` black-on-black — payloads that hide a row as
# effectively as conceal — and the count assertion below would then be counting
# an attacker's escapes as the palette's. These are the literal strings the
# printer can emit; anything else left in the output is not ours.
mapfile -t PALETTE < <(sed -n "s/^[A-Z_][A-Z_]*=\\\$'\\\\033\\[\\([0-9;]*\\)m'.*/\\1/p" "$CLI" | sort -u)
[[ ${#PALETTE[@]} -ge 6 ]] \
  && pass "the palette was read from the tool's own constants (${#PALETTE[@]} of them)" \
  || fail "could not read the palette out of $CLI; the strip below would be meaningless"
strip_palette() {
  local prog='' p
  for p in "${PALETTE[@]}"; do prog+="s/\\x1b\\[${p}m//g;"; done
  sed -e "$prog"
}
esc_count() { tr -cd "$ESC" | wc -c | tr -d ' '; }
# Raw 8-bit C1 (0x80-0x9F). On a terminal in 8-bit mode 0x9B *is* CSI, and this
# tool emits nothing outside ASCII plus the palette, so any of these bytes in the
# output came from the stream.
c1_count() { LC_ALL=C tr -cd '\200-\237' | wc -c | tr -d ' '; }

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
  # The same attack in its 8-bit form. C1 has two encodings and only one of them
  # is an ESC: the byte 0x9B *is* CSI on a terminal in 8-bit mode, 0x9D is OSC,
  # 0x9C is ST. A strip that drops ESC and the UTF-8 spelling (0xC2 0x9B) but not
  # the bare byte leaves exactly the encoding that is dangerous in the one
  # situation the strip exists for. Written on a passthrough line because a JSON
  # document may not carry a bare 0x9B.
  printf 'plain ERROR raw8 \233[1;32mGREEN \233[2K \235PWNED8BIT\234 done\n'
  # And the same character in its UTF-8 spelling: the two bytes 0xC2 0x9B, sat
  # directly in the JSON string. That is the encoding a terminal decoding UTF-8
  # really does execute as CSI, so it is the half that must never survive.
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"utf8c1 [1;32mGREEN2"}]}}'
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

# The 8-bit half. ESC is not the only way to say CSI: the single byte 0x9B is
# CSI, 0x9D is OSC and 0x9C is ST on a terminal in 8-bit mode, and a strip built
# out of [[:cntrl:]] plus the UTF-8 form covers neither. The tool prints nothing
# outside ASCII and its own palette, so one of these bytes in the output can only
# have come from the stream.
c1=$(printf '%s' "$out" | c1_count)
[[ "$c1" == "0" ]] \
  && pass "no raw 8-bit C1 byte from the stream reaches the terminal" \
  || fail "$c1 raw C1 bytes (0x80-0x9F) reached the terminal:\n$(printf '%s' "$out" | cat -v)"

for payload in $'\233[1;32m' $'\233[2K' $'\235PWNED8BIT' $'\302\233[1;32m'; do
  if printf '%s' "$out" | grep -qaF "$payload"; then
    fail "an 8-bit payload survived: $(printf '%s' "$payload" | cat -v)"
  else
    pass "no $(printf '%s' "$payload" | cat -v) in the output"
  fi
done

echo "--- sanitising neuters the bytes, it does not swallow the content ---"

for word in 'narration' 'FLEET GREEN' 'hidden.txt' 'PWNEDTITLE' 'real failure here' \
            '0 errors, all tests passed' 'BLINK' 'forged' 'GREEN2' 'PWNED8BIT'; do
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
