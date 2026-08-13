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
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
LIB="$TP_ROOT/lib/pump-lib.sh"

# Hermeticity: ignore any taskpump.conf in the repo this suite happens to run
# from — the tools discover config by walking up from $PWD, and a leaked conf
# reconfigures every fixture invocation below. run-all.sh exports the same
# switch; this one covers standalone runs.
export TASKPUMP_NO_CONF=1

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

# The prefix is pinned per invocation (the examples/arachne.conf value): what
# these cases assert is the counting, not the prefix's default spelling, which
# is tp-agent- since G1.5.
names=$'arachne-agent-feat-a\narachne-agent-feat-b'
got=$(TASKPUMP_AGENT_PREFIX=arachne-agent- DOCKER="$BIN/docker" STUB_NAMES="$names" apl_count_live_agents)
[[ "$got" == "2" ]] && pass "counts 2 live arachne-agent containers" \
  || fail "expected 2 live agents got '$got'"
got=$(TASKPUMP_AGENT_PREFIX=arachne-agent- DOCKER="$BIN/docker" STUB_NAMES="" apl_count_live_agents)
[[ "$got" == "0" ]] && pass "counts 0 when no agents are live" \
  || fail "expected 0 live agents got '$got'"
# Slug filter (rotation tops up a specific phase's pool).
got=$(TASKPUMP_AGENT_PREFIX=arachne-agent- DOCKER="$BIN/docker" STUB_NAMES="$names" apl_count_live_agents "feat-a")
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

echo "--- agent identity: one prefix, one runtime, one enumeration ---"
# The container-name prefix is the stack's join key. Its default must not drift
# unannounced (tooling outside this repo greps for it), and it must be
# overridable in one place rather than re-hardcoded per tool.
# Bare default, deliberately: the shipped spelling is TaskPump's own (G1.5).
# The historical arachne-agent- spelling survives only as the arachne.conf pin.
[[ "$(apl_agent_prefix)" == "tp-agent-" ]] \
  && pass "bare default agent prefix is tp-agent-" \
  || fail "default prefix drifted: '$(apl_agent_prefix)'"
# Conf-pinned: the reference consumer's spelling survives the flip.
[[ "$(TASKPUMP_AGENT_PREFIX=arachne-agent- apl_agent_prefix)" == "arachne-agent-" ]] \
  && pass "the arachne.conf pin keeps the historical prefix" \
  || fail "pinned prefix ignored"
[[ "$(TASKPUMP_AGENT_PREFIX=tp-agent- apl_agent_prefix)" == "tp-agent-" ]] \
  && pass "TASKPUMP_AGENT_PREFIX overrides the prefix" \
  || fail "prefix override ignored"

# The runtime override was the real defect: three of the five enumerations
# called `docker` literally, so a harness that stubbed it still hit the daemon.
cat >| "$BIN/fake-runtime" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "ps" ]]; then printf '%s\n' "${STUB_NAMES:-}"; exit 0; fi
exit 0
EOF
chmod +x "$BIN/fake-runtime"
[[ "$(TASKPUMP_DOCKER="$BIN/fake-runtime" apl_docker)" == "$BIN/fake-runtime" ]] \
  && pass "TASKPUMP_DOCKER selects the container runtime" \
  || fail "TASKPUMP_DOCKER ignored"
[[ "$(DOCKER="$BIN/fake-runtime" apl_docker)" == "$BIN/fake-runtime" ]] \
  && pass "legacy DOCKER still selects the container runtime" \
  || fail "legacy DOCKER ignored"

# Prefix pinned per invocation here too — enumeration mechanics are the
# subject, not the default spelling (tp-agent- since G1.5).
mixed=$'arachne-agent-feat-a\nsome-other-container\narachne-agent-feat-b'
got=$(TASKPUMP_AGENT_PREFIX=arachne-agent- DOCKER="$BIN/fake-runtime" STUB_NAMES="$mixed" apl_live_agent_names | tr '\n' ' ')
[[ "$got" == "arachne-agent-feat-a arachne-agent-feat-b " ]] \
  && pass "live enumeration keeps only prefixed containers" \
  || fail "unexpected enumeration: '$got'"
got=$(TASKPUMP_AGENT_PREFIX=arachne-agent- DOCKER="$BIN/fake-runtime" STUB_NAMES="$mixed" apl_live_agent_slugs | tr '\n' ' ')
[[ "$got" == "feat-a feat-b " ]] \
  && pass "slugs are names minus the prefix" \
  || fail "unexpected slugs: '$got'"
renamed=$'tp-agent-feat-a\narachne-agent-feat-b'
got=$(TASKPUMP_AGENT_PREFIX=tp-agent- DOCKER="$BIN/fake-runtime" STUB_NAMES="$renamed" apl_live_agent_slugs | tr '\n' ' ')
[[ "$got" == "feat-a " ]] \
  && pass "a custom prefix selects and strips consistently" \
  || fail "custom prefix enumeration: '$got'"

# The tolerant form flattens "I could not look" into "nothing is live", which is
# right for the pump's tick (guessing none costs one wasted launch decision) and
# wrong for a runner answering `list`, whose caller must be able to tell the two
# apart before deciding to fall back (docs/RUNNERS.md §1.3). Both forms exist for
# that reason, over ONE filter expression — the drift these tests are for is a
# second `docker ps --filter` growing next to the first.
cat >| "$BIN/dead-runtime" <<'EOF'
#!/usr/bin/env bash
printf 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock.\n' >&2
exit 1
EOF
chmod +x "$BIN/dead-runtime"

got=$(DOCKER="$BIN/dead-runtime" apl_live_agent_names 2>/dev/null); rc=$?
[[ $rc -eq 0 && -z "$got" ]] \
  && pass "the tolerant enumeration reads an unreachable runtime as no agents" \
  || fail "apl_live_agent_names should stay quiet and succeed; rc=$rc got='$got'"

got=$(DOCKER="$BIN/dead-runtime" apl_live_agent_names_strict 2>/dev/null); rc=$?
[[ $rc -ne 0 && -z "$got" ]] \
  && pass "the strict enumeration propagates an unreachable runtime" \
  || fail "apl_live_agent_names_strict swallowed a runtime failure; rc=$rc got='$got'"

err=$(DOCKER="$BIN/dead-runtime" apl_live_agent_names_strict 2>&1 >/dev/null)
[[ "$err" == *"Cannot connect to the Docker daemon"* ]] \
  && pass "the strict enumeration leaves the runtime's stderr for its caller to word" \
  || fail "the runtime's reason was swallowed: '$err'"

got=$(TASKPUMP_AGENT_PREFIX=arachne-agent- DOCKER="$BIN/fake-runtime" STUB_NAMES="$mixed" apl_live_agent_names_strict | tr '\n' ' '); rc=$?
[[ $rc -eq 0 && "$got" == "arachne-agent-feat-a arachne-agent-feat-b " ]] \
  && pass "strict and tolerant select the same names when the runtime answers" \
  || fail "strict enumeration diverged: rc=$rc '$got'"

got=$(DOCKER="$BIN/fake-runtime" apl_live_agent_names_strict | wc -c); rc=$?
[[ $rc -eq 0 && "$got" -eq 0 ]] \
  && pass "an empty fleet is zero bytes, not a blank line" \
  || fail "empty strict enumeration emitted $got bytes"

echo "--- liveness delegates to the runner, and never lies when it cannot ---"
# The point of the delegation: a runner that starts something other than a
# container has agents no `docker ps` will ever show. Scraping reads them as
# dead, and the supervisor launches over them. So these stubs deliberately make
# the runner's answer and the runtime's answer DIFFERENT — a test where both say
# the same thing cannot tell which one was asked.

# A v2 runner: knows `list`, and reports an agent the container runtime does not.
cat >| "$BIN/runner-v2" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list) [[ -n "${STUB_RUNNER_NAMES:-}" ]] && printf '%s\n' "$STUB_RUNNER_NAMES"; exit 0 ;;
  launch|stop) exit 0 ;;
  *) echo "runner: unknown verb: ${1:-}" >&2; exit 2 ;;
esac
EOF
# A v1 runner: the documented pre-v2 skeleton. An unknown verb is a usage error,
# which is exit 2 — that is the code the capability probe reads as "no verb".
cat >| "$BIN/runner-v1" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  launch|stop) exit 0 ;;
  *) echo "runner: unknown verb: ${1:-}" >&2; exit 2 ;;
esac
EOF
# A v2 runner whose runtime has gone away mid-run: it HAS the verb and cannot
# answer it. Exit 1, not 2 — the distinction the probe rests on.
cat >| "$BIN/runner-v2-broken" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list) echo "runner.sh: cannot list agents (rc=1): daemon unreachable" >&2; exit 1 ;;
  launch|stop) exit 0 ;;
  *) echo "runner: unknown verb: ${1:-}" >&2; exit 2 ;;
esac
EOF
chmod +x "$BIN/runner-v2" "$BIN/runner-v1" "$BIN/runner-v2-broken"

# live_via <runner> [var=value]... — one liveness read, with the capability cache
# cleared so each case probes for itself. Prints slugs; returns the status.
live_via() {
  local runner="$1"; shift
  (
    unset APL_RUNNER_LIST_CAP
    local kv; for kv in "$@"; do export "$kv"; done
    APL_LIVENESS_RUNNER="$runner" DOCKER="$BIN/fake-runtime" apl_live_agent_slugs
  )
}

# Populated: the runner's fleet, not the runtime's.
got=$(live_via "$BIN/runner-v2" STUB_RUNNER_NAMES=$'tp-agent-feat-a\ntp-agent-feat-b' STUB_NAMES=tp-agent-feat-zzz | tr '\n' ' '); rc=$?
[[ $rc -eq 0 && "$got" == "feat-a feat-b " ]] \
  && pass "liveness comes from the runner when it supports list" \
  || fail "runner-backed liveness wrong (rc=$rc): '$got'"

# Empty: the runner says nothing is live even though the runtime shows a
# container. An empty answer from a runner that ANSWERED is authoritative.
got=$(live_via "$BIN/runner-v2" STUB_NAMES=tp-agent-feat-zzz | tr '\n' ' '); rc=$?
[[ $rc -eq 0 && -z "$got" ]] \
  && pass "an empty runner answer is authoritative, not a reason to scrape" \
  || fail "empty runner answer was overridden (rc=$rc): '$got'"

# A name outside this pump's prefix cannot be mapped back to one of its
# branches, so the prefix filter applies to the runner's answer too.
got=$(live_via "$BIN/runner-v2" STUB_RUNNER_NAMES=$'tp-agent-feat-a\nsomeone-elses-agent' | tr '\n' ' ')
[[ "$got" == "feat-a " ]] \
  && pass "the prefix filter applies to the runner's answer as well" \
  || fail "an unprefixed name survived: '$got'"

# v1 runner: no verb, so the scrape stands. This is the compatibility promise —
# an existing runner keeps working untouched.
got=$(live_via "$BIN/runner-v1" STUB_NAMES=$'tp-agent-feat-a\ntp-agent-feat-b' | tr '\n' ' '); rc=$?
[[ $rc -eq 0 && "$got" == "feat-a feat-b " ]] \
  && pass "a v1 runner falls back to container-name enumeration" \
  || fail "v1 fallback wrong (rc=$rc): '$got'"

# Not executable / not there at all: same fallback, no crash.
got=$(live_via "$TMP/no-such-runner" STUB_NAMES=tp-agent-feat-a | tr '\n' ' '); rc=$?
[[ $rc -eq 0 && "$got" == "feat-a " ]] \
  && pass "a missing runner falls back instead of failing the tick" \
  || fail "missing-runner fallback wrong (rc=$rc): '$got'"

# The mid-run failure. Two properties, and the second is the one that matters:
# the answer is still the scrape (fail-open, the pump must not wedge), AND the
# status says it is not authoritative (so an absence-driven pass can decline).
got=$(live_via "$BIN/runner-v2-broken" STUB_NAMES=tp-agent-feat-a | tr '\n' ' '); rc=$?
[[ "$got" == "feat-a " ]] \
  && pass "a runner that errors mid-run falls back to the scrape rather than failing" \
  || fail "degraded liveness returned nothing usable: '$got'"
[[ $rc -eq "$APL_LIVENESS_DEGRADED_RC" ]] \
  && pass "a degraded answer is flagged with exit $APL_LIVENESS_DEGRADED_RC" \
  || fail "degraded liveness looked authoritative (rc=$rc)"

# The whole reason the status exists. For a NON-container runner the fallback
# scrape is not stale, it is EMPTY — "every agent died at once". A caller that
# reclaims claims or resumes phases on absence must be able to see that this
# answer is worthless, or one bad tick reclaims the entire fleet.
got=$(live_via "$BIN/runner-v2-broken" | tr '\n' ' '); rc=$?
[[ -z "$got" && $rc -eq "$APL_LIVENESS_DEGRADED_RC" ]] \
  && pass "a blind answer that looks like 'everything died' is flagged, not silent" \
  || fail "the everything-died answer was unflagged (rc=$rc): '$got'"

# A supported runner that answers normally must NOT be flagged, or the guard
# would skip reclaim forever and orphaned claims would never be freed.
got=$(live_via "$BIN/runner-v2" | tr '\n' ' '); rc=$?
[[ -z "$got" && $rc -eq 0 ]] \
  && pass "a genuinely empty fleet is authoritative, so reclaim still runs" \
  || fail "an empty-but-answered fleet was flagged degraded (rc=$rc)"

echo "--- the capability probe: exit 2 means 'no such verb', anything else does not ---"

# Probed once, then cached: a supervisor asks liveness every tick and must not
# pay a probe each time.
( unset APL_RUNNER_LIST_CAP
  apl_runner_list_supported "$BIN/runner-v2" && [[ "$APL_RUNNER_LIST_CAP" == "1" ]] ) \
  && pass "a v2 runner probes as supported and caches the answer" \
  || fail "v2 capability probe failed"

( unset APL_RUNNER_LIST_CAP
  ! apl_runner_list_supported "$BIN/runner-v1" && [[ "$APL_RUNNER_LIST_CAP" == "0" ]] ) \
  && pass "a v1 runner (exit 2) probes as unsupported and caches the answer" \
  || fail "v1 capability probe failed"

# The distinction that keeps a transient blip from disabling the runner for the
# whole run: a runtime error is NOT a missing verb. Misreading it would mean a
# non-container runner's agents stay invisible until the pump restarts.
( unset APL_RUNNER_LIST_CAP
  apl_runner_list_supported "$BIN/runner-v2-broken" ) \
  && pass "a runner whose runtime is down still counts as supporting list" \
  || fail "a transient runtime failure was misread as a v1 runner"

# The cache is honoured, not re-derived: a probe result carried in from the
# parent shell (which is how the pump caches across per-tick subshells) wins.
got=$(APL_RUNNER_LIST_CAP=0 APL_LIVENESS_RUNNER="$BIN/runner-v2" DOCKER="$BIN/fake-runtime" \
      STUB_RUNNER_NAMES=tp-agent-feat-a STUB_NAMES=tp-agent-feat-b apl_live_agent_slugs | tr '\n' ' ')
[[ "$got" == "feat-b " ]] \
  && pass "an inherited 'unsupported' verdict is reused, not re-probed" \
  || fail "the cached capability was ignored: '$got'"

echo "--- pool cap: one shared fallback, not three private ones ---"
CAP_FILE="$TMP/absent-cap"
[[ "$(JOBS=4 apl_read_cap)" == "4" ]] && pass "caller's JOBS wins when no cap file exists" \
  || fail "expected 4 got '$(JOBS=4 apl_read_cap)'"
got=$(unset JOBS; apl_read_cap)
[[ "$got" == "6" ]] && pass "no JOBS at all falls back to TASKPUMP_JOBS_FALLBACK (6)" \
  || fail "expected the shared fallback 6, got '$got'"
got=$(unset JOBS; TASKPUMP_JOBS_FALLBACK=9 apl_read_cap)
[[ "$got" == "9" ]] && pass "TASKPUMP_JOBS_FALLBACK is configurable" \
  || fail "expected 9 got '$got'"

echo "--- help extraction: a marker, not a line range ---"
# `sed -n '2,40p' "$0"` truncated the moment anyone edited a header, silently.
cat >| "$TMP/helpy" <<'EOF'
#!/usr/bin/env bash
# a tool that does something
#   --flag   does the thing
# HELP-END
# this internal note must NOT reach --help
set -e
EOF
got="$(apl_help "$TMP/helpy")"
[[ "$got" == $'a tool that does something\n  --flag   does the thing' ]] \
  && pass "help stops at HELP-END and strips the comment prefix" \
  || fail "unexpected help text: '$got'"
printf '#!/usr/bin/env bash\n# only line\nset -e\n' >| "$TMP/helpy2"
[[ "$(apl_help "$TMP/helpy2")" == "only line" ]] \
  && pass "help ends at the first non-comment line when unmarked" \
  || fail "unmarked help extraction wrong"

echo "--- Test 27: the integration trunk's own run files are not contamination ---"
# The first --integration-trunk run creates two untracked files in the repo
# root. They were in neither .gitignore nor the guard's allowlist, so every tick
# for the rest of the drain reported a dirty primary checkout.
FSG="$TMP/fsg"; mkdir -p "$FSG"
git -C "$FSG" init -q -b main
git -C "$FSG" config user.name t; git -C "$FSG" config user.email t@t
printf 'x\n' >| "$FSG/tracked.txt"; git -C "$FSG" add -A; git -C "$FSG" -c commit.gpgsign=false commit -qm seed
[[ -z "$(apl_fs_guard "$FSG")" ]] && pass "a clean checkout is silent" || fail "clean checkout reported dirty"
: >| "$FSG/.auto-trunk.lock"
: >| "$FSG/.auto-trunk-quarantine"
[[ -z "$(apl_fs_guard "$FSG")" ]] && pass "the trunk lock and quarantine file are allowlisted" \
  || fail "trunk run files reported as contamination: $(apl_fs_guard "$FSG")"
printf 'edited\n' >| "$FSG/tracked.txt"
[[ -n "$(apl_fs_guard "$FSG")" ]] && pass "a real source edit is still reported" \
  || fail "source edit went unreported"

echo "--- gitignore repair: the ignore line is a knob, anchored and escaped ---"
GI="$TMP/gi"; mkdir -p "$GI"
printf '!.worktrees/\n!.worktrees/**\ntarget/\n.worktrees/\n' >| "$GI/.gitignore"
apl_repair_worktree_gitignore "$GI"
grep -qxF '.worktrees/' "$GI/.gitignore" && fail "the bare re-ignore line survived" \
  || pass "the bare re-ignore line is stripped"
grep -qxF '!.worktrees/' "$GI/.gitignore" && pass "the negations are left alone" \
  || fail "a negation was stripped too"
grep -qxF 'target/' "$GI/.gitignore" && pass "unrelated lines are left alone" \
  || fail "an unrelated line was stripped"
printf 'build/wt/\n!build/wt/**\n' >| "$GI/.gitignore"
TASKPUMP_WORKTREES_IGNORE_LINE='build/wt/' apl_repair_worktree_gitignore "$GI"
grep -qxF 'build/wt/' "$GI/.gitignore" && fail "a configured ignore line was not stripped" \
  || pass "TASKPUMP_WORKTREES_IGNORE_LINE picks the line to strip"
grep -qxF '!build/wt/**' "$GI/.gitignore" && pass "its negation survives" || fail "negation stripped"

echo "--- ensure worktrees visible: an operator-global excludes is overridden ---"
# The 2026-08-13 dogfood canary: a global core.excludesFile ignoring
# **/.worktrees/** in every repo made the pump skip every launch. The heal must
# land in the repo's own info/exclude — never in a tracked file, never in the
# operator's global config.
EV="$TMP/ev"; mkdir -p "$EV"
git -C "$EV" init -q -b main
GX="$TMP/global-ignore"; printf '**/.worktrees/**\n' >| "$GX"
git -C "$EV" config core.excludesFile "$GX"
mkdir -p "$EV/.worktrees/feat/x"
git -C "$EV" check-ignore -q .worktrees/feat/x \
  && pass "control: the fixture's global excludes ignores the worktree" \
  || fail "control: fixture global excludes is inert — the test proves nothing"
apl_ensure_worktrees_visible "$EV" "$EV/.worktrees/feat/x" \
  && pass "ensure reports the worktree visible" || fail "ensure returned still-ignored"
git -C "$EV" check-ignore -q .worktrees/feat/x \
  && fail "worktree still ignored after ensure" \
  || pass "the global excludes is overridden"
grep -qxF -- '!.worktrees/**' "$EV/.git/info/exclude" \
  && pass "the negation landed in info/exclude" || fail "info/exclude has no negation"
[[ -z "$(git -C "$EV" status --porcelain 2>/dev/null)" || "$(git -C "$EV" status --porcelain)" == *".worktrees"* ]] \
  && pass "no tracked file was touched by the heal" || fail "heal dirtied the tree: $(git -C "$EV" status --porcelain)"
ev_lines=$(wc -l < "$EV/.git/info/exclude")
apl_ensure_worktrees_visible "$EV" "$EV/.worktrees/feat/x" || fail "re-run returned still-ignored"
[[ "$ev_lines" -eq "$(wc -l < "$EV/.git/info/exclude")" ]] \
  && pass "idempotent: a second ensure appends nothing" || fail "info/exclude grew on re-run"
# The bare .gitignore line outranks info/exclude; both halves must compose.
printf '.worktrees/\n' >| "$EV/.gitignore"
apl_ensure_worktrees_visible "$EV" "$EV/.worktrees/feat/x" \
  && pass "combined sources heal too (bare line + global excludes)" \
  || fail "combined sources defeat ensure"
git -C "$EV" check-ignore -q .worktrees/feat/x \
  && fail "still ignored with combined sources" || pass "visible after the combined heal"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]]
