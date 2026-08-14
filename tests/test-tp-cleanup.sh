#!/bin/bash
# test-arachne-cleanup.sh -- fixture tests for the disk-reclaim path:
#   * arachne-cleanup --targets reclaims worktree target/ dirs (only when a
#     reclaim command is configured; unconfigured it touches nothing), skips any
#     worktree with a live agent container, and (with --include-primary) also
#     reclaims the primary checkout's target/.
#   * arachne-disk-watchdog's PANIC state invokes that reclaim before pruning
#     docker, gated by PANIC_RECLAIM_TARGETS.
# Everything runs in --dry-run against a throwaway fixture tree with a stub
# `docker` and a stub `arachne-cleanup`, so no real target/ is ever deleted.
set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
TP_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
CLEANUP="$TP_ROOT/libexec/tp-cleanup"
WATCHDOG="$TP_ROOT/libexec/tp-disk-watchdog"

# Hermeticity: ignore any taskpump.conf in the repo this suite happens to run
# from — the tools discover config by walking up from $PWD, and a leaked conf
# reconfigures every fixture invocation below. run-all.sh exports the same
# switch; this one covers standalone runs.
export TASKPUMP_NO_CONF=1

# Reference pin (G1.2): the live-agent skip in Test 3 matches the stub's
# arachne-agent-* container name through this prefix. It used to arrive through
# the baked default, which G1.5 flips to tp-agent-; the historical spelling is
# pinned here with the examples/arachne.conf value.
export TASKPUMP_AGENT_PREFIX=arachne-agent-

# Reference pin (G1.7): the --targets sweep runs only when a reclaim command is
# configured — the bare default touches nothing. The sweep's cargo-shaped
# target/ logic is exercised under the examples/arachne.conf pin; Test 0 checks
# the unconfigured no-op.
export TASKPUMP_RECLAIM_CMD='cargo clean'

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
# assert_has <description> <haystack> <needle>
assert_has() { [[ "$2" == *"$3"* ]] && pass "$1" || { fail "$1"; echo "  expected to contain: $3"; }; }
assert_no()  { [[ "$2" != *"$3"* ]] && pass "$1" || { fail "$1"; echo "  expected NOT to contain: $3"; }; }

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

# ── Fixture tree: two worktree target/ dirs + a primary target/. feat/a has a
#    Cargo.toml (cargo-clean branch), feat/b does not (rm -rf fallback branch).
mkdir -p "$FIX/.worktrees/feat/a/target" "$FIX/.worktrees/feat/b/target" "$FIX/target"
: > "$FIX/.worktrees/feat/a/target/x"; : > "$FIX/.worktrees/feat/a/Cargo.toml"
: > "$FIX/.worktrees/feat/b/target/x"
: > "$FIX/target/x"; : > "$FIX/Cargo.toml"

# ── Stub docker on PATH: `docker ps` emits $STUB_LIVE (a container name) or
#    nothing. Everything else is a no-op success.
mkdir -p "$FIX/bin"
cat > "$FIX/bin/docker" <<'EOF'
#!/bin/bash
if [[ "$1" == "ps" ]]; then [[ -n "${STUB_LIVE:-}" ]] && printf '%s\n' "$STUB_LIVE"; exit 0; fi
exit 0
EOF
chmod +x "$FIX/bin/docker"
export PATH="$FIX/bin:$PATH"

echo "--- Test 0: --targets with no reclaim command configured touches nothing (G1.7) ---"
# The bare default: TASKPUMP_RECLAIM_CMD unset means the sweep is a no-op that
# says so — a rescue tool guessing at a toolchain's build dirs is worse than one
# that reports itself unconfigured.
out="$(TASKPUMP_RECLAIM_CMD= ARACHNE_CLEANUP_REPO_ROOT="$FIX" STUB_LIVE="" "$CLEANUP" --targets --dry-run 2>&1)"
assert_has "unconfigured sweep logs the no-op line" "$out" "target reclaim skipped: TASKPUMP_RECLAIM_CMD unconfigured"
assert_no  "unconfigured sweep lists no worktree"   "$out" "$FIX/.worktrees/feat/a/target"
assert_no  "unconfigured sweep plans no command"    "$out" "(dry-run)"
[[ -f "$FIX/.worktrees/feat/a/target/x" && -f "$FIX/.worktrees/feat/b/target/x" ]] \
  && pass "unconfigured sweep left both target/ dirs intact" \
  || fail "unconfigured sweep touched a target/ dir"
# --include-primary changes nothing while unconfigured.
out="$(TASKPUMP_RECLAIM_CMD= ARACHNE_CLEANUP_REPO_ROOT="$FIX" STUB_LIVE="" "$CLEANUP" --targets --include-primary --dry-run 2>&1)"
assert_no  "unconfigured sweep ignores --include-primary" "$out" "primary: $FIX/target"

echo "--- Test 1: --targets --dry-run reclaims both worktrees, leaves primary ---"
# The cargo-shaped target/ sweep, under the suite-level examples/arachne.conf
# pin TASKPUMP_RECLAIM_CMD='cargo clean' (G1.7: configured is what arms it).
out="$(ARACHNE_CLEANUP_REPO_ROOT="$FIX" STUB_LIVE="" "$CLEANUP" --targets --dry-run 2>&1)"
assert_has "feat/a target listed"            "$out" "$FIX/.worktrees/feat/a/target"
assert_has "feat/b target listed"            "$out" "$FIX/.worktrees/feat/b/target"
assert_has "reclaimed 2, skipped 0 live"     "$out" "reclaimed 2 worktree target dir(s); skipped 0 live"
assert_has "primary left alone by default"   "$out" "left alone (pass --include-primary to reclaim)"
assert_no  "primary not reclaimed by default" "$out" "primary: $FIX/target"
if command -v cargo >/dev/null 2>&1; then
  assert_has "feat/a uses cargo clean (Cargo.toml present)" "$out" "cargo clean --manifest-path '$FIX/.worktrees/feat/a/Cargo.toml'"
  assert_has "feat/b falls back to rm -rf (no Cargo.toml)"  "$out" "rm -rf '$FIX/.worktrees/feat/b/target'"
else
  echo "  (cargo not installed — skipping cargo-clean branch assertion)"
fi

echo "--- Test 2: --include-primary also reclaims the primary checkout ---"
out="$(ARACHNE_CLEANUP_REPO_ROOT="$FIX" STUB_LIVE="" "$CLEANUP" --targets --include-primary --dry-run 2>&1)"
assert_has "primary target reclaimed"        "$out" "primary: $FIX/target"
# RECLAIM_PRIMARY=1 env is equivalent to the flag.
out="$(ARACHNE_CLEANUP_REPO_ROOT="$FIX" RECLAIM_PRIMARY=1 STUB_LIVE="" "$CLEANUP" --targets --dry-run 2>&1)"
assert_has "RECLAIM_PRIMARY=1 == --include-primary" "$out" "primary: $FIX/target"

echo "--- Test 3: a worktree with a live agent container is skipped ---"
out="$(ARACHNE_CLEANUP_REPO_ROOT="$FIX" STUB_LIVE="arachne-agent-feat-a" "$CLEANUP" --targets --dry-run 2>&1)"
assert_has "feat/a skipped (live agent)"     "$out" "skip: $FIX/.worktrees/feat/a/target — live agent container"
assert_has "reclaimed 1, skipped 1 live"     "$out" "reclaimed 1 worktree target dir(s); skipped 1 live."
assert_no  "feat/a not acted on while live"  "$out" "worktree: $FIX/.worktrees/feat/a/target"
assert_has "feat/b still reclaimed"          "$out" "worktree: $FIX/.worktrees/feat/b/target"

echo "--- Test 4: watchdog PANIC invokes target reclaim before docker prune ---"
# Stub tp-cleanup so the watchdog's reclaim/docker calls are observable and fast
# (no scan of the real worktrees). The watchdog resolves its siblings against its
# own install root, so the stub only takes effect inside a throwaway copy of that
# install — hence a fixture tree holding the watchdog, config.sh, and the stub.
# A copy, not a symlink: TP_ROOT comes from `readlink -f`, which would follow a
# symlink straight back to the real installation.
TPFIX="$FIX/taskpump"
mkdir -p "$TPFIX/libexec" "$TPFIX/lib"
cp "$WATCHDOG" "$TPFIX/libexec/tp-disk-watchdog"
cp "$TP_ROOT/lib/config.sh" "$TPFIX/lib/config.sh"
# pump-lib too: the watchdog now counts live agents and prints its help through
# the shared helpers instead of carrying its own copies.
cp "$TP_ROOT/lib/pump-lib.sh" "$TPFIX/lib/pump-lib.sh"
cat > "$TPFIX/libexec/tp-cleanup" <<'EOF'
#!/bin/bash
echo "STUB-CLEANUP-CALLED args: $*"
EOF
chmod +x "$TPFIX/libexec/tp-disk-watchdog" "$TPFIX/libexec/tp-cleanup"
WATCHDOG="$TPFIX/libexec/tp-disk-watchdog"

out="$(ARACHNE_DISK_REPO_ROOT="$FIX" FREE_GB_OVERRIDE=3 PANIC_THRESHOLD_GB=5 PAUSE_THRESHOLD_GB=10 \
       "$WATCHDOG" --once --dry-run 2>&1)"
assert_has "panic state entered (free=3 < panic=5)" "$out" "HEALTHY → PANIC"
# Toolchain-neutral wording (G1.7): the watchdog names no build system.
assert_has "reclaim_targets ran"                    "$out" "reclaiming build target/ dirs (worktrees + primary)"
assert_has "cleanup invoked with targets+primary+dry-run" "$out" "STUB-CLEANUP-CALLED args: --targets --include-primary --dry-run"
assert_has "docker prune still attempted"           "$out" "would run tp-cleanup --docker"

echo "--- Test 5: PANIC_RECLAIM_TARGETS=0 disables the target reclaim ---"
out="$(ARACHNE_DISK_REPO_ROOT="$FIX" FREE_GB_OVERRIDE=3 PANIC_THRESHOLD_GB=5 PANIC_RECLAIM_TARGETS=0 \
       "$WATCHDOG" --once --dry-run 2>&1)"
assert_no  "no target reclaim when disabled"        "$out" "STUB-CLEANUP-CALLED"
assert_has "docker prune still runs when disabled"  "$out" "would run tp-cleanup --docker"

echo "--- Test 6: PAUSED (free in pause band) does NOT reclaim targets ---"
out="$(ARACHNE_DISK_REPO_ROOT="$FIX" FREE_GB_OVERRIDE=7 PANIC_THRESHOLD_GB=5 PAUSE_THRESHOLD_GB=10 \
       "$WATCHDOG" --once --dry-run 2>&1)"
assert_has "paused state entered (5 < 7 < 10)"      "$out" "HEALTHY → PAUSED"
assert_no  "no target reclaim while merely paused"  "$out" "STUB-CLEANUP-CALLED"

echo "--- Test 7: EXTRA_BUSY_DIRS skips listed worktrees and the primary ---"
out="$(ARACHNE_CLEANUP_REPO_ROOT="$FIX" STUB_LIVE="" EXTRA_BUSY_DIRS="$FIX/.worktrees/feat/a" "$CLEANUP" --targets --dry-run 2>&1)"
assert_has "feat/a skipped via EXTRA_BUSY_DIRS"  "$out" "skip: $FIX/.worktrees/feat/a/target — busy (EXTRA_BUSY_DIRS)"
assert_has "feat/b still reclaimed"              "$out" "worktree: $FIX/.worktrees/feat/b/target"
out="$(ARACHNE_CLEANUP_REPO_ROOT="$FIX" STUB_LIVE="" EXTRA_BUSY_DIRS="$FIX" "$CLEANUP" --targets --include-primary --dry-run 2>&1)"
assert_has "busy primary skipped despite --include-primary" "$out" "skip: $FIX/target — busy (EXTRA_BUSY_DIRS)"
assert_no  "busy primary not reclaimed"          "$out" "primary: $FIX/target"

echo "--- Test 8: --stuck maps container→task from the LEDGER claim, no manifest (#7) ---"
# tp-cleanup used to default TASKPUMP_MANIFEST to Arachne's
# ops/task-loop/parallel-manifest.tsv — an artifact TaskPump does not ship. The
# canonical mapping is now the ledger's live in_progress claim (via
# tp-dag-render --claims, the same source the monitor reads), so a consumer
# that never had a manifest gets a full rescue: stop AND release.
CT="$FIX/tasks"; mkdir -p "$FIX/tasks"
mkclaim() {  # $1 = id, $2 = claimed_by branch, $3 = status
  printf -- '---\nid: "%s"\nphase: "T1"\nstatus: %s\nclaimed_by: %s\nclaimed_at: "2026-08-13T10:00:00Z"\nlast_heartbeat_ts: "2026-08-13T10:30:00Z"\nturn_budget_remaining: 4\ngoal: "the %s outcome"\nblockers: []\n---\nbody\n' \
    "$1" "$3" "$2" "$1" >| "$CT/$1.md"
}
mkclaim T1.1 feat/a in_progress
touch -d '2 hours ago' "$FIX/.worktrees/feat/a/.taskpump-agent.log"
out="$(TASKPUMP_CLEANUP_REPO_ROOT="$FIX" TASKPUMP_TASKS_DIR="$CT" \
       TASKPUMP_PUMP_STATE_FILE="$FIX/no-pump-state" \
       STUB_LIVE="arachne-agent-feat-a" "$CLEANUP" --stuck --dry-run 2>&1)"
assert_has "the stale-log agent is detected"           "$out" "STUCK (log idle"
assert_has "the release comes from the ledger claim"   "$out" "release 'T1.1'"
assert_no  "no reference to the retired Arachne path"  "$out" "parallel-manifest"

echo "--- Test 9: --stuck with no claim and no manifest skips the release LOUDLY ---"
mkdir -p "$FIX/.worktrees/feat/b"
touch -d '2 hours ago' "$FIX/.worktrees/feat/b/.taskpump-agent.log"
out="$(TASKPUMP_CLEANUP_REPO_ROOT="$FIX" TASKPUMP_TASKS_DIR="$CT" \
       TASKPUMP_PUMP_STATE_FILE="$FIX/no-pump-state" \
       STUB_LIVE="arachne-agent-feat-b" "$CLEANUP" --stuck --dry-run 2>&1)"
assert_has "the container is still stopped"            "$out" "docker stop"
assert_has "the skip names its reason"                 "$out" "no live ledger claim"
assert_has "the skip is explicit, not silent"          "$out" "skipping the task release"
assert_no  "nothing was released on a guess"           "$out" "release '"

echo "--- Test 10: a configured manifest that does not exist is a loud error (#7) ---"
# Same rule as TASKPUMP_CONFIG: an explicit request for a specific file must
# not silently fall back. Both spellings name themselves in the error.
merr="$(TASKPUMP_MANIFEST="$FIX/no-such.tsv" TASKPUMP_CLEANUP_REPO_ROOT="$FIX" \
        "$CLEANUP" --stuck --dry-run 2>&1)"; mrc=$?
[[ "$mrc" -ne 0 ]] && pass "explicit missing manifest exits non-zero" \
                   || fail "explicit missing manifest exited 0"
assert_has "the error names the key that was set"      "$merr" "TASKPUMP_MANIFEST names"
assert_has "the error names the missing path"          "$merr" "$FIX/no-such.tsv"
berr="$(MANIFEST="$FIX/no-such.tsv" TASKPUMP_CLEANUP_REPO_ROOT="$FIX" \
        "$CLEANUP" --stuck --dry-run 2>&1)"; brc=$?
[[ "$brc" -ne 0 ]] && pass "the bare MANIFEST spelling errors too" \
                   || fail "bare MANIFEST missing file exited 0"
assert_has "the bare spelling names ITS key"           "$berr" "ERROR: MANIFEST names"
TASKPUMP_MANIFEST="$FIX/no-such.tsv" "$CLEANUP" --help >/dev/null 2>&1 \
  && pass "--help still works with a bad manifest configured" \
  || fail "--help blocked by the manifest check"

echo "--- Test 11: an opt-in manifest is a FALLBACK; the ledger claim outranks it ---"
# feat/a holds a live claim on T1.1 while the manifest says T9.8 — the claim
# wins (the manifest row is a launch-time constant that goes stale). feat/b has
# no claim, so the manifest's T9.9 row is what saves that release.
printf 'mnamea\tfeat/a\tbrief\tT9.8\nmnameb\tfeat/b\tbrief\tT9.9\n' >| "$FIX/manifest.tsv"
out="$(TASKPUMP_MANIFEST="$FIX/manifest.tsv" TASKPUMP_CLEANUP_REPO_ROOT="$FIX" \
       TASKPUMP_TASKS_DIR="$CT" TASKPUMP_PUMP_STATE_FILE="$FIX/no-pump-state" \
       STUB_LIVE=$'arachne-agent-feat-a\narachne-agent-feat-b' \
       "$CLEANUP" --stuck --dry-run 2>&1)"
assert_has "the live ledger claim outranks the manifest row" "$out" "release 'T1.1'"
assert_no  "the stale manifest row for feat/a is not used"   "$out" "T9.8"
assert_has "the manifest still rescues a claim-less branch"  "$out" "release 'T9.9'"

echo "--- Test 12: the rescue sees claims OUTSIDE the pump state's phase range ---"
# The renderer narrows --claims to the pump state's phases, but a stuck agent
# is typically exactly the one the range moved past — ledger_claims must
# neutralize the narrowing or the release silently skips at rc=0.
mkclaim_ph() {  # $1 = id, $2 = phase, $3 = claimed_by branch
  printf -- '---\nid: "%s"\nphase: "%s"\nstatus: in_progress\nclaimed_by: %s\nclaimed_at: "2026-08-13T10:00:00Z"\nlast_heartbeat_ts: "2026-08-13T10:30:00Z"\nturn_budget_remaining: 4\ngoal: "the %s outcome"\nblockers: []\n---\nbody\n' \
    "$1" "$2" "$3" "$1" >| "$CT/$1.md"
}
mkclaim_ph T5.1 T5 feat/c
mkdir -p "$FIX/.worktrees/feat/c"
touch -d '2 hours ago' "$FIX/.worktrees/feat/c/.taskpump-agent.log"
printf '{"phases":"T1"}\n' >| "$FIX/pump.state"
out="$(TASKPUMP_CLEANUP_REPO_ROOT="$FIX" TASKPUMP_TASKS_DIR="$CT" \
       TASKPUMP_PUMP_STATE_FILE="$FIX/pump.state" \
       STUB_LIVE="arachne-agent-feat-c" "$CLEANUP" --stuck --dry-run 2>&1)"
assert_has "the out-of-range claim is still released"   "$out" "release 'T5.1'"
assert_no  "no silent skip for the out-of-range claim"  "$out" "no live ledger claim"

echo "--- Test 13: TASKPUMP_MANIFEST_SUBPATH reaches tp-cleanup (monitor parity) ---"
# The repo-relative spelling the monitor honours must not be silently inert
# here — that is the explicit-config-silently-ignored shape issue #7 closes.
serr="$(TASKPUMP_MANIFEST_SUBPATH="missing/nope.tsv" TASKPUMP_CLEANUP_REPO_ROOT="$FIX" \
        "$CLEANUP" --stuck --dry-run 2>&1)"; src=$?
[[ "$src" -ne 0 ]] && pass "a missing SUBPATH manifest exits non-zero" \
                   || fail "a missing SUBPATH manifest exited 0"
assert_has "the error names the SUBPATH key" "$serr" "TASKPUMP_MANIFEST_SUBPATH names"
printf 'mnamed\tfeat/d\tbrief\tT9.7\n' >| "$FIX/sub-manifest.tsv"
mkdir -p "$FIX/.worktrees/feat/d"
touch -d '2 hours ago' "$FIX/.worktrees/feat/d/.taskpump-agent.log"
out="$(TASKPUMP_MANIFEST_SUBPATH="sub-manifest.tsv" TASKPUMP_CLEANUP_REPO_ROOT="$FIX" \
       TASKPUMP_TASKS_DIR="$CT" TASKPUMP_PUMP_STATE_FILE="$FIX/no-pump-state" \
       STUB_LIVE="arachne-agent-feat-d" "$CLEANUP" --stuck --dry-run 2>&1)"
assert_has "a SUBPATH manifest rescues a claim-less branch" "$out" "release 'T9.7'"

echo "--- Test 14: a broken claim renderer is loud, never a fake 'no claim' ---"
out="$(TASKPUMP_DAG_BIN=/bin/false TASKPUMP_CLEANUP_REPO_ROOT="$FIX" \
       TASKPUMP_TASKS_DIR="$CT" TASKPUMP_PUMP_STATE_FILE="$FIX/no-pump-state" \
       STUB_LIVE="arachne-agent-feat-b" "$CLEANUP" --stuck --dry-run 2>&1)"
assert_has "a failing renderer is named"      "$out" "ledger claim renderer failed"
out="$(TASKPUMP_DAG_BIN="$FIX/no-such-renderer" TASKPUMP_CLEANUP_REPO_ROOT="$FIX" \
       TASKPUMP_TASKS_DIR="$CT" TASKPUMP_PUMP_STATE_FILE="$FIX/no-pump-state" \
       STUB_LIVE="arachne-agent-feat-b" "$CLEANUP" --stuck --dry-run 2>&1)"
assert_has "a missing renderer is named"      "$out" "renderer not executable"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ "$FAIL" -eq 0 ]]
