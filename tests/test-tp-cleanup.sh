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

# Hermeticity: the shared prologue ignores any taskpump.conf in the repo this
# suite happens to run from (a leaked conf reconfigures every fixture
# invocation below) and scrubs the pump-exported TASKPUMP_*/TP_*/ARACHNE_*
# environment (issue #18). run-all.sh sources the same prologue; this one
# covers standalone runs.
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"

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
assert_has "unconfigured sweep logs the no-op line" "$out" "build reclaim skipped: TASKPUMP_RECLAIM_CMD unconfigured"
assert_no  "unconfigured sweep lists no worktree"   "$out" "$FIX/.worktrees/feat/a/target"
assert_no  "unconfigured sweep plans no command"    "$out" "(dry-run)"
[[ -f "$FIX/.worktrees/feat/a/target/x" && -f "$FIX/.worktrees/feat/b/target/x" ]] \
  && pass "unconfigured sweep left both target/ dirs intact" \
  || fail "unconfigured sweep touched a target/ dir"
# --include-primary changes nothing while unconfigured.
out="$(TASKPUMP_RECLAIM_CMD= ARACHNE_CLEANUP_REPO_ROOT="$FIX" STUB_LIVE="" "$CLEANUP" --targets --include-primary --dry-run 2>&1)"
assert_no  "unconfigured sweep ignores --include-primary" "$out" "primary: $FIX/target"

echo "--- Test 1: --targets --dry-run reclaims both worktrees, leaves primary ---"
# The target/-probed sweep, under the suite-level examples/arachne.conf pin
# TASKPUMP_RECLAIM_CMD='cargo clean' (G1.7: configured is what arms it).
out="$(ARACHNE_CLEANUP_REPO_ROOT="$FIX" STUB_LIVE="" "$CLEANUP" --targets --dry-run 2>&1)"
assert_has "feat/a target listed"            "$out" "$FIX/.worktrees/feat/a/target"
assert_has "feat/b target listed"            "$out" "$FIX/.worktrees/feat/b/target"
assert_has "reclaimed 2, skipped 0"          "$out" "reclaimed 2 worktree workspace(s); skipped 0."
assert_has "primary left alone by default"   "$out" "left alone (pass --include-primary to reclaim)"
assert_no  "primary not reclaimed by default" "$out" "primary: $FIX/target"
# B9: the CONFIGURED command is what runs, in the workspace, in both workspaces.
# It used to be a switch that armed a hardcoded `cargo clean` / `rm -rf target`
# pair, so a consumer who set this key to their project's actual reclaim command
# got the Rust sweep instead — and a consumer whose build output lives anywhere
# else got a pass that reported success having freed nothing.
assert_has "the configured command runs in feat/a" "$out" "(dry-run) cd $FIX/.worktrees/feat/a && cargo clean"
assert_has "the configured command runs in feat/b" "$out" "(dry-run) cd $FIX/.worktrees/feat/b && cargo clean"
assert_no  "no hardcoded rm -rf of the probe dir"  "$out" "rm -rf"
assert_no  "no hardcoded cargo --manifest-path"    "$out" "--manifest-path"

echo "--- Test 2: --include-primary also reclaims the primary checkout ---"
out="$(ARACHNE_CLEANUP_REPO_ROOT="$FIX" STUB_LIVE="" "$CLEANUP" --targets --include-primary --dry-run 2>&1)"
assert_has "primary target reclaimed"        "$out" "primary: $FIX/target"
# RECLAIM_PRIMARY=1 env is equivalent to the flag.
out="$(ARACHNE_CLEANUP_REPO_ROOT="$FIX" RECLAIM_PRIMARY=1 STUB_LIVE="" "$CLEANUP" --targets --dry-run 2>&1)"
assert_has "RECLAIM_PRIMARY=1 == --include-primary" "$out" "primary: $FIX/target"

echo "--- Test 3: a worktree with a live agent container is skipped ---"
out="$(ARACHNE_CLEANUP_REPO_ROOT="$FIX" STUB_LIVE="arachne-agent-feat-a" "$CLEANUP" --targets --dry-run 2>&1)"
assert_has "feat/a skipped (live agent)"     "$out" "skip: $FIX/.worktrees/feat/a — live agent container"
assert_has "reclaimed 1, skipped 1"          "$out" "reclaimed 1 worktree workspace(s); skipped 1."
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
echo "STUB-CLEANUP-ROOT: ${TASKPUMP_CLEANUP_REPO_ROOT:-<unset>}"
EOF
chmod +x "$TPFIX/libexec/tp-disk-watchdog" "$TPFIX/libexec/tp-cleanup"
WATCHDOG="$TPFIX/libexec/tp-disk-watchdog"

out="$(ARACHNE_DISK_REPO_ROOT="$FIX" FREE_GB_OVERRIDE=3 PANIC_THRESHOLD_GB=5 PAUSE_THRESHOLD_GB=10 \
       "$WATCHDOG" --once --dry-run 2>&1)"
assert_has "panic state entered (free=3 < panic=5)" "$out" "HEALTHY → PANIC"
# Toolchain-neutral wording (G1.7): the watchdog names no build system.
assert_has "reclaim_targets ran"                    "$out" "reclaiming build output (worktrees + primary)"
assert_has "cleanup invoked with targets+primary+dry-run" "$out" "STUB-CLEANUP-CALLED args: --targets --include-primary --dry-run"
# The panic sweep must run against the workspace this watchdog guards. cleanup
# resolves its own root from its install dir, so without this it walks the
# TaskPump checkout's worktrees and frees nothing (B8's wrong-root family).
assert_has "the sweep is pointed at the guarded workspace" "$out" "STUB-CLEANUP-ROOT: $FIX"
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

echo "--- Test 7: the busy-workspace skip, in BOTH spellings AT ONCE (B5) ---"
# The documented spelling is TASKPUMP_EXTRA_BUSY_DIRS, and it used to be read by
# nobody: the tool tested the bare EXTRA_BUSY_DIRS only, so the key an operator
# set to protect a mid-compile workspace reclaimed exactly that workspace. Both
# spellings are honoured now — as a UNION, because ranking them re-creates the
# same harm through whichever spelling loses (the disk-guard chain passes the
# bare name on its command line while a conf, or config.sh's ARACHNE_ bridge,
# supplies the prefixed one). The skip line names the spelling that matched.
out="$(ARACHNE_CLEANUP_REPO_ROOT="$FIX" STUB_LIVE="" EXTRA_BUSY_DIRS="$FIX/.worktrees/feat/a" "$CLEANUP" --targets --dry-run 2>&1)"
assert_has "feat/a skipped via the legacy EXTRA_BUSY_DIRS" "$out" "skip: $FIX/.worktrees/feat/a — busy (EXTRA_BUSY_DIRS)"
assert_has "feat/b still reclaimed"              "$out" "worktree: $FIX/.worktrees/feat/b/target"
out="$(ARACHNE_CLEANUP_REPO_ROOT="$FIX" STUB_LIVE="" TASKPUMP_EXTRA_BUSY_DIRS="$FIX/.worktrees/feat/a" "$CLEANUP" --targets --dry-run 2>&1)"
assert_has "feat/a skipped via the canonical TASKPUMP_EXTRA_BUSY_DIRS" "$out" "skip: $FIX/.worktrees/feat/a — busy (TASKPUMP_EXTRA_BUSY_DIRS)"
assert_no  "the protected workspace is not reclaimed"  "$out" "cd $FIX/.worktrees/feat/a &&"
assert_has "feat/b is still reclaimed alongside it"    "$out" "worktree: $FIX/.worktrees/feat/b/target"
# BOTH lists apply when both are set. This is the assertion the fallback shipped
# without: setting the canonical key silently unprotected every workspace the
# legacy one named, so a conf line (or an inherited ARACHNE_EXTRA_BUSY_DIRS) was
# enough to delete the build output a command-line EXTRA_BUSY_DIRS was set to
# save — B5's own harm, through the other spelling.
out="$(ARACHNE_CLEANUP_REPO_ROOT="$FIX" STUB_LIVE="" \
       TASKPUMP_EXTRA_BUSY_DIRS="$FIX/.worktrees/feat/a" EXTRA_BUSY_DIRS="$FIX/.worktrees/feat/b" \
       "$CLEANUP" --targets --dry-run 2>&1)"
assert_has "the canonical list still protects its entry" "$out" "skip: $FIX/.worktrees/feat/a — busy (TASKPUMP_EXTRA_BUSY_DIRS)"
assert_has "and the legacy list protects its own"        "$out" "skip: $FIX/.worktrees/feat/b — busy (EXTRA_BUSY_DIRS)"
assert_no  "neither workspace is reclaimed"              "$out" "(dry-run) cd $FIX/.worktrees/feat/"
assert_has "both are counted as skipped, none reclaimed" "$out" "reclaimed 0 worktree workspace(s); skipped 2."
# An entry named by both lists says so rather than picking a winner.
out="$(ARACHNE_CLEANUP_REPO_ROOT="$FIX" STUB_LIVE="" \
       TASKPUMP_EXTRA_BUSY_DIRS="$FIX/.worktrees/feat/a" EXTRA_BUSY_DIRS="$FIX/.worktrees/feat/a" \
       "$CLEANUP" --targets --dry-run 2>&1)"
assert_has "an entry in both lists names both spellings" "$out" "busy (TASKPUMP_EXTRA_BUSY_DIRS + EXTRA_BUSY_DIRS)"
# ...and the same union on the primary arm, which is the one the unattended
# PANIC sweep drives with --include-primary.
out="$(ARACHNE_CLEANUP_REPO_ROOT="$FIX" STUB_LIVE="" \
       TASKPUMP_EXTRA_BUSY_DIRS="$FIX/.worktrees/feat/a" EXTRA_BUSY_DIRS="$FIX" \
       "$CLEANUP" --targets --include-primary --dry-run 2>&1)"
assert_has "the legacy list still protects the primary"  "$out" "skip: $FIX — busy (EXTRA_BUSY_DIRS)"
assert_no  "the primary is not reclaimed"                "$out" "primary: $FIX/target"
out="$(ARACHNE_CLEANUP_REPO_ROOT="$FIX" STUB_LIVE="" EXTRA_BUSY_DIRS="$FIX" "$CLEANUP" --targets --include-primary --dry-run 2>&1)"
assert_has "busy primary skipped despite --include-primary" "$out" "skip: $FIX — busy (EXTRA_BUSY_DIRS)"
assert_no  "busy primary not reclaimed"          "$out" "primary: $FIX/target"
out="$(ARACHNE_CLEANUP_REPO_ROOT="$FIX" STUB_LIVE="" TASKPUMP_EXTRA_BUSY_DIRS="$FIX" "$CLEANUP" --targets --include-primary --dry-run 2>&1)"
assert_has "the canonical spelling protects the primary too" "$out" "skip: $FIX — busy (TASKPUMP_EXTRA_BUSY_DIRS)"
assert_no  "the canonically-protected primary is not reclaimed" "$out" "primary: $FIX/target"

echo "--- Test 7b: the reclaim probe dir is configurable (B9) ---"
# Every reclaim path used to be gated on a directory literally named `target/`,
# so on a workspace that builds anywhere else the sweep freed nothing and said
# it had succeeded. TASKPUMP_RECLAIM_DIR names the directory that means "this
# workspace is holding build output"; empty turns the precondition off.
B9="$FIX/b9"; mkdir -p "$B9/.worktrees/feat/n/node_modules" "$B9/.worktrees/feat/p"
out="$(TASKPUMP_CLEANUP_REPO_ROOT="$B9" STUB_LIVE="" TASKPUMP_RECLAIM_CMD='npm run clean' \
       "$CLEANUP" --targets --dry-run 2>&1)"
assert_has "a non-Rust workspace reclaims nothing under the default probe" "$out" "nothing to reclaim: no workspace under $B9/.worktrees/*/* has a target/"
assert_has "and the diagnostic names the key that fixes it" "$out" "set TASKPUMP_RECLAIM_DIR"
assert_no  "nothing was planned against it"                 "$out" "(dry-run) cd"
out="$(TASKPUMP_CLEANUP_REPO_ROOT="$B9" STUB_LIVE="" TASKPUMP_RECLAIM_CMD='npm run clean' \
       TASKPUMP_RECLAIM_DIR=node_modules "$CLEANUP" --targets --dry-run 2>&1)"
assert_has "the configured probe finds the workspace"  "$out" "worktree: $B9/.worktrees/feat/n/node_modules"
assert_has "and runs the configured command there"     "$out" "(dry-run) cd $B9/.worktrees/feat/n && npm run clean"
assert_no  "the probe-less workspace is left alone"    "$out" "cd $B9/.worktrees/feat/p"
out="$(TASKPUMP_CLEANUP_REPO_ROOT="$B9" STUB_LIVE="" TASKPUMP_RECLAIM_CMD='npm run clean' \
       TASKPUMP_RECLAIM_DIR='' "$CLEANUP" --targets --dry-run 2>&1)"
assert_has "an empty probe runs the command in every idle workspace" "$out" "(dry-run) cd $B9/.worktrees/feat/p && npm run clean"
# An empty probe also removes the last precondition on the PRIMARY arm, which
# the disk watchdog's unattended sweep always requests. The tool says so where
# it happens rather than leaving the operator to infer it.
out="$(TASKPUMP_CLEANUP_REPO_ROOT="$B9" STUB_LIVE="" TASKPUMP_RECLAIM_CMD='npm run clean' \
       TASKPUMP_RECLAIM_DIR='' "$CLEANUP" --targets --include-primary --dry-run 2>&1)"
assert_has "the unconditional primary arm is announced" "$out" "TASKPUMP_RECLAIM_DIR is empty, so there is no precondition on this arm"
assert_has "and it names the key that holds it back"    "$out" "TASKPUMP_EXTRA_BUSY_DIRS"

echo "--- Test 7c: a reclaim command that FAILS is never counted as a reclaim ---"
# The summary used to contradict the WARNING one line above it: reclaim_workspace
# logged the failure and returned 0 anyway, so the sweep counted it, reported
# "reclaimed N", and handed the unattended PANIC sweep rc 0 having freed nothing.
# The old hardcoded `rm -rf` essentially never failed; an arbitrary consumer
# command does. Non-dry-run, with a command that fails in exactly one workspace.
RF="$FIX/reclaim-fail"
mkdir -p "$RF/.worktrees/feat/x/target" "$RF/.worktrees/feat/y/target"
: >| "$RF/.worktrees/feat/x/ok"
head -c 4096 /dev/zero >| "$RF/.worktrees/feat/y/target/big"
out="$(TASKPUMP_CLEANUP_REPO_ROOT="$RF" STUB_LIVE="" TASKPUMP_RECLAIM_CMD='test -f ok' \
       "$CLEANUP" --targets 2>&1)"; rc=$?
assert_has "the failing workspace is warned about"   "$out" "WARNING: TASKPUMP_RECLAIM_CMD failed in $RF/.worktrees/feat/y"
assert_has "the summary counts it as a failure"      "$out" "reclaimed 1 worktree workspace(s); skipped 0; FAILED 1"
assert_no  "and does not count it as a reclaim"      "$out" "reclaimed 2 worktree"
assert_has "the sweep names its own exit status"     "$out" "exit 3"
[[ "$rc" -eq 3 ]] && pass "a failed reclaim exits 3, not 0" \
                  || fail "expected exit 3 from a failed reclaim, got $rc"
[[ -f "$RF/.worktrees/feat/y/target/big" ]] \
  && pass "the space the summary did not claim is indeed still on disk" \
  || fail "the fixture's build output vanished; the assertion above proves nothing"
# --all must carry it too: `do_stuck; do_targets; do_docker` would otherwise
# report the LAST step's status and lose the failure entirely.
out="$(TASKPUMP_CLEANUP_REPO_ROOT="$RF" STUB_LIVE="" TASKPUMP_RECLAIM_CMD='test -f ok' \
       "$CLEANUP" --all 2>&1)"; rc=$?
[[ "$rc" -eq 3 ]] && pass "--all still exits 3 when the reclaim step failed" \
                  || fail "expected exit 3 from --all, got $rc"
# ...and a sweep whose command works still exits 0.
out="$(TASKPUMP_CLEANUP_REPO_ROOT="$RF" STUB_LIVE="" TASKPUMP_RECLAIM_CMD='true' \
       "$CLEANUP" --targets 2>&1)"; rc=$?
[[ "$rc" -eq 0 ]] && pass "a sweep whose command succeeds still exits 0" \
                  || fail "expected exit 0 from a clean sweep, got $rc: $out"
assert_no  "and reports no failures"                 "$out" "FAILED"

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
assert_has "the release comes from the ledger claim"   "$out" "release T1.1 "
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
assert_no  "nothing was released on a guess"           "$out" "tp-task release"

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
assert_has "the live ledger claim outranks the manifest row" "$out" "release T1.1 "
assert_no  "the stale manifest row for feat/a is not used"   "$out" "T9.8"
assert_has "the manifest still rescues a claim-less branch"  "$out" "release T9.9 "

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
assert_has "the out-of-range claim is still released"   "$out" "release T5.1 "
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
assert_has "a SUBPATH manifest rescues a claim-less branch" "$out" "release T9.7 "

echo "--- Test 14: a broken claim renderer is loud, never a fake 'no claim' ---"
out="$(TASKPUMP_DAG_BIN=/bin/false TASKPUMP_CLEANUP_REPO_ROOT="$FIX" \
       TASKPUMP_TASKS_DIR="$CT" TASKPUMP_PUMP_STATE_FILE="$FIX/no-pump-state" \
       STUB_LIVE="arachne-agent-feat-b" "$CLEANUP" --stuck --dry-run 2>&1)"
assert_has "a failing renderer is named"      "$out" "ledger claim renderer failed"
out="$(TASKPUMP_DAG_BIN="$FIX/no-such-renderer" TASKPUMP_CLEANUP_REPO_ROOT="$FIX" \
       TASKPUMP_TASKS_DIR="$CT" TASKPUMP_PUMP_STATE_FILE="$FIX/no-pump-state" \
       STUB_LIVE="arachne-agent-feat-b" "$CLEANUP" --stuck --dry-run 2>&1)"
assert_has "a missing renderer is named"      "$out" "renderer not executable"

echo "--- Test 15: a ledger task id carrying a shell metacharacter is REFUSED ---"
# PI-C1, the operator-machine RCE. The rescue reads the task id out of a task
# file's frontmatter and used to splice it into a command string that act()
# ended in `eval`. A single quote in the id closes that quoting, and the rest of
# it runs as the operator, on the host, from a watchdog running unattended — and
# a task file is writable by anything that can write the repo (an agent with a
# bind-mounted checkout, a merged pull request), never having passed the
# create-time id check. Two independent things are asserted here: the payload
# does not execute, and the malformed id is refused with a diagnostic rather
# than passed on.
PWN="$FIX/CLEANUP_PWNED"
rm -f "$PWN"
# Written straight to disk under a well-behaved FILE name, because that is the
# shape of the attack: nothing forces a task file's frontmatter id to be the
# name of the file it lives in, and nothing but `tp task create` — which this
# writer bypasses exactly as an agent or a merged PR does — ever checked it.
mkclaim_file() {  # $1 = file, $2 = id, $3 = claimed_by branch
  printf -- '---\nid: "%s"\nphase: "G9"\nstatus: in_progress\nclaimed_by: %s\nclaimed_at: "2026-08-13T10:00:00Z"\nlast_heartbeat_ts: "2026-08-13T10:30:00Z"\nturn_budget_remaining: 4\ngoal: "poisoned"\nblockers: []\n---\nbody\n' \
    "$2" "$3" >| "$1"
}
mkclaim_file "$CT/G9-poison.md" "G9.1'; touch $PWN; echo '" feat/e
mkdir -p "$FIX/.worktrees/feat/e"
touch -d '2 hours ago' "$FIX/.worktrees/feat/e/.taskpump-agent.log"
out="$(TASKPUMP_CLEANUP_REPO_ROOT="$FIX" TASKPUMP_TASKS_DIR="$CT" \
       TASKPUMP_PUMP_STATE_FILE="$FIX/no-pump-state" \
       STUB_LIVE="arachne-agent-feat-e" "$CLEANUP" --stuck 2>&1)"
[[ ! -e "$PWN" ]] && pass "the payload in the task id did not execute" \
                  || fail "the id was evaluated: $PWN exists"
assert_has "the poisoned id is named and refused"  "$out" "WARN: ignoring the live ledger claim held by branch 'feat/e'"
assert_has "the diagnostic says what is wrong"     "$out" "which is not safe in a path or a command argument"
assert_has "the remedy names the file to fix"      "$out" "Fix the task file's frontmatter"
assert_no  "no release was attempted with it"      "$out" "tp-task release"
# A REFUSED claim is not a MISSING one, and must not borrow the missing one's
# line: `no live ledger claim (and no manifest row) maps this container to a
# task` is documented (CLI-TOOLS.md) as meaning a container that maps to
# NEITHER source, and this container maps to a claim the tool just named on
# stderr. Reporting the wrong reason is the defect class this whole change is
# about, committed by the fix for it.
assert_no  "the refusal does not claim there was no claim" "$out" "no live ledger claim (and no manifest row)"
assert_has "the refusal has its own line"          "$out" "the live ledger claim for this container names an id this tool refuses to pass on"
assert_has "which says the claim is still held"    "$out" "its task claim is NOT released"
assert_has "and how to finish the job by hand"     "$out" "tp task release <id>"
rm -f "$CT/G9-poison.md"

# The same distinction from the manifest side, where the remedy is a different
# file: a bad id in a TSV row is not in any task file and `tp task fsck` will
# never name it.
printf 'mname\tfeat/f\tbrief\tT9.9;rm -rf /\n' >| "$FIX/bad-manifest.tsv"
mkdir -p "$FIX/.worktrees/feat/f"
touch -d '2 hours ago' "$FIX/.worktrees/feat/f/.taskpump-agent.log"
out="$(TASKPUMP_MANIFEST="$FIX/bad-manifest.tsv" TASKPUMP_CLEANUP_REPO_ROOT="$FIX" \
       TASKPUMP_TASKS_DIR="$CT" TASKPUMP_PUMP_STATE_FILE="$FIX/no-pump-state" \
       STUB_LIVE="arachne-agent-feat-f" "$CLEANUP" --stuck --dry-run 2>&1)"
assert_has "a poisoned manifest id is refused too"  "$out" "WARN: ignoring the manifest row for branch 'feat/f'"
assert_has "and the remedy names the manifest, not a task file" "$out" "Fix that row in $FIX/bad-manifest.tsv"
assert_no  "not the task-file remedy"               "$out" "tp task fsck"
assert_has "the refusal names the manifest row"     "$out" "the manifest row for this container names an id this tool refuses to pass on"
assert_no  "and does not report a missing mapping"  "$out" "no live ledger claim (and no manifest row)"
rm -f "$FIX/bad-manifest.tsv"

# The project's own grammar is enforced too, once the consumer has one: an id
# that is filename-safe but outside TASKPUMP_ID_PATTERN is REPORTED and still
# released. Safety refuses; grammar only warns. `ZZ9` is one safe argv word —
# nothing about it needs escaping — so refusing to free the wedged agent over
# the project's naming convention would strand the claim, and `tp task fsck
# --fix` filters on the same pattern and will not repair the file either.
mkclaim ZZ9 feat/e in_progress
out="$(TASKPUMP_CLEANUP_REPO_ROOT="$FIX" TASKPUMP_TASKS_DIR="$CT" \
       TASKPUMP_ID_PATTERN='^T[0-9]+(\.[0-9]+)?$' \
       TASKPUMP_PUMP_STATE_FILE="$FIX/no-pump-state" \
       STUB_LIVE="arachne-agent-feat-e" "$CLEANUP" --stuck --dry-run 2>&1)"
assert_has "an off-grammar id is named"            "$out" "does not match TASKPUMP_ID_PATTERN"
assert_has "the warning says it proceeds anyway"   "$out" "Proceeding anyway"
assert_has "and the rescue still releases it"      "$out" "release ZZ9 --reason"
# ...and an UNSAFE id is still refused no matter how permissive the grammar is.
rm -f "$CT/ZZ9.md"
mkclaim_file "$CT/G9-poison.md" "G9.1'; touch $PWN; echo '" feat/e
out="$(TASKPUMP_CLEANUP_REPO_ROOT="$FIX" TASKPUMP_TASKS_DIR="$CT" \
       TASKPUMP_ID_PATTERN='.*' \
       TASKPUMP_PUMP_STATE_FILE="$FIX/no-pump-state" \
       STUB_LIVE="arachne-agent-feat-e" "$CLEANUP" --stuck --dry-run 2>&1)"
assert_has "a permissive grammar cannot admit an unsafe id" "$out" "not safe in a path or a command argument"
assert_no  "and it still never reaches a release"           "$out" "tp-task release"
rm -f "$CT/G9-poison.md"

echo "--- Test 16: a worktree directory name is data, not shell (PI-D4) ---"
# The same defect through the other door: `$dir` comes from a glob over the
# worktrees base, so anyone who can create a directory there chose the bytes
# that reached the eval. The sweep must neither execute them nor pretend the
# workspace was reclaimed.
# The canary is written relative to the sweep's own working directory, which is
# where the substitution would land — and a name with no `/` in it, so the
# fixture is one directory rather than a tree mkdir -p invented.
D4="$FIX/d4"; CANARY="D4_PWNED"
rm -f "$D4/$CANARY"
# The apostrophe is the whole attack: it closes the single quote the tool
# wrapped the path in, and everything after it is parsed as shell.
mkdir -p "$D4/.worktrees/feat/x'\$(touch $CANARY)'y/target" "$D4/.worktrees/feat/ok/target"
out="$(cd "$D4" && TASKPUMP_CLEANUP_REPO_ROOT="$D4" STUB_LIVE="" TASKPUMP_RECLAIM_CMD='echo RECLAIMED' \
       "$CLEANUP" --targets 2>&1)"
[[ ! -e "$D4/$CANARY" ]] && pass "a command substitution in a directory name did not run" \
                         || fail "the directory name was evaluated: $D4/$CANARY exists"
assert_has "the unsafe workspace is skipped by name" "$out" "worktree directory"
assert_has "and the well-named one is still reclaimed" "$out" "cd $D4/.worktrees/feat/ok && echo RECLAIMED"

echo "--- Test 17: the watchdog drives the WORKSPACE's cap file, not the install's (B8) ---"
# The cap file is the documented choke point between these two processes: the
# watchdog writes it, the pump reads it. The watchdog used to default its root
# to the parent of its own script dir — the INSTALLATION — so from a consumer
# workspace it wrote a cap file the pump never looks at, logged "pool cap → 0",
# and the pump kept launching at full cap. It resolves the workspace the same
# way the pump does now.
WS="$FIX/ws"; mkdir -p "$WS/tasks"
git -C "$WS" init -q >/dev/null 2>&1
rm -f "$TPFIX/.taskpump-pool-cap" "$WS/.taskpump-pool-cap"
out="$(cd "$WS" && FREE_GB_OVERRIDE=7 PANIC_THRESHOLD_GB=5 PAUSE_THRESHOLD_GB=10 \
       "$WATCHDOG" --once 2>&1)"
assert_has "the pause names the workspace's cap file" "$out" "→ 0 ($WS/.taskpump-pool-cap)"
[[ -f "$WS/.taskpump-pool-cap" ]] \
  && pass "the cap file lands in the workspace the pump reads" \
  || fail "no cap file at $WS/.taskpump-pool-cap"
[[ ! -f "$TPFIX/.taskpump-pool-cap" ]] \
  && pass "and the installation's own root was not written" \
  || fail "the watchdog wrote the install's cap file at $TPFIX/.taskpump-pool-cap"
# ...and what it writes is a 0 the shared reader honours, which is the other
# half of B8: apl_read_cap used to require >= 1 and threw this 0 away.
capval="$(cat "$WS/.taskpump-pool-cap")"
[[ "$capval" == "0" ]] && pass "the paused cap written is 0" || fail "expected 0, got '$capval'"
got="$(CAP_FILE="$WS/.taskpump-pool-cap" JOBS=4 bash -c '. "$1"; apl_read_cap' _ "$TP_ROOT/lib/pump-lib.sh")"
[[ "$got" == "0" ]] \
  && pass "and the shared cap reader answers 0, so nothing launches" \
  || fail "apl_read_cap discarded the watchdog's 0: got '$got'"

echo "--- Test 18: the pause dies with the watchdog holding it ---"
# The other half of honouring a 0: nothing used to expire, clear or refresh one.
# A watchdog killed mid-pressure left its 0 behind, the pump does not overwrite
# an existing cap file without --jobs, and so the NEXT unattended run capped at
# 0 — launching nothing, reporting `status: running`, paging nobody. Exactly such
# a file was found in the primary checkout. Three mechanisms close it: the pause
# is re-stamped while it is held, it is handed back when the loop exits, and a
# watchdog that starts against somebody's stale 0 does not adopt it as the cap to
# restore to.
CAPF="$WS/.taskpump-pool-cap"
FREEF="$FIX/free-gb"          # the probe's output, rewritten mid-run
cap_now()  { tr -dc '0-9' < "$CAPF" 2>/dev/null; }
free_set() { printf 'Avail\n%sG\n' "$1" >| "$FREEF"; }
# await <seconds> <snippet> -- poll until the snippet succeeds. The snippet is a
# STRING re-evaluated each round; passing an already-expanded command would
# compare the same stale value fifty times and always time out.
await() {
  local deadline=$(( $(date +%s) + $1 )) snip="$2"
  while (( $(date +%s) < deadline )); do
    eval "$snip" && return 0
    sleep 0.2
  done
  return 1
}
watchdog_bg() {  # start the watch loop against $WS with the file-driven probe
  TASKPUMP_DISK_REPO_ROOT="$WS" TASKPUMP_DISK_PROBE="cat $FREEF" \
    PANIC_THRESHOLD_GB=5 PAUSE_THRESHOLD_GB=10 RECOVER_THRESHOLD_GB=20 POLL=1 \
    "$WATCHDOG" >|"$FIX/wd.log" 2>&1 &
  WD_PID=$!
}

# 1) A watchdog that STARTS against somebody's stale 0 must not adopt it as the
#    cap to restore to, or its recovery holds the very wedge it was launched to
#    clear.
printf '0\n' >| "$CAPF"
free_set 7            # PAUSED
watchdog_bg
# Wait for the PAUSE to be REACHED before relieving the pressure — the cap file
# already reads 0, so polling its contents would return true before the loop had
# taken a single reading.
await 15 'grep -q "HEALTHY → PAUSED" "$FIX/wd.log"' || true
free_set 99           # → HEALTHY, which restores ORIGINAL_CAP
if await 15 '[[ "$(cap_now)" != "0" ]]'; then
  pass "a watchdog that inherits a 0 recovers to a real cap, not to 0"
else
  fail "the watchdog 'recovered' the workspace to cap 0: $(cat "$FIX/wd.log")"
fi
kill -TERM "$WD_PID" 2>/dev/null; wait "$WD_PID" 2>/dev/null
assert_has "and it said why at startup" "$(cat "$FIX/wd.log")" "held 0, which is a pause and not a cap"

# 2) A held pause is re-stamped every poll — that mtime is the liveness signal
#    the reader expires an abandoned 0 against — and 3) it is handed back when
#    the loop exits, so a stopped watchdog cannot pause the next run.
printf '5\n' >| "$CAPF"
free_set 7
watchdog_bg
if await 15 '[[ "$(cap_now)" == "0" ]]'; then
  pass "the watch loop writes the pause"
  touch -d '2 hours ago' "$CAPF"      # age it by hand; a live holder puts it back
  stale_mt="$(stat -c '%Y' "$CAPF")"
  if await 15 '[[ "$(stat -c "%Y" "$CAPF" 2>/dev/null)" != "$stale_mt" ]]'; then
    pass "and re-stamps it every poll while it still holds it"
  else
    fail "the held pause was never refreshed (mtime still $stale_mt); the reader would expire it under a live watchdog"
  fi
else
  fail "the watch loop never wrote the pause: $(cat "$FIX/wd.log")"
fi
kill -TERM "$WD_PID" 2>/dev/null; wait "$WD_PID" 2>/dev/null
capval="$(cap_now)"
[[ "$capval" == "5" ]] \
  && pass "and hands the cap back on the way out, so no dead process pauses the next run" \
  || fail "the watchdog left '$capval' in the cap file after exiting"
assert_has "the release says why it is doing it" "$(cat "$FIX/wd.log")" "would pause the next run too"

# 4) The heartbeat is only worth anything if it beats faster than the reader's
#    patience, so a poll at or above the window is named rather than left to be
#    found out as a pump that resumed launching under live pressure.
out="$(TASKPUMP_DISK_REPO_ROOT="$WS" FREE_GB_OVERRIDE=99 POLL=1200 \
       TASKPUMP_POOL_CAP_STALE_SEC=900 "$WATCHDOG" --once 2>&1)"
assert_has "a poll longer than the staleness window is a named warning" "$out" "poll 1200s >= TASKPUMP_POOL_CAP_STALE_SEC 900s"
out="$(TASKPUMP_DISK_REPO_ROOT="$WS" FREE_GB_OVERRIDE=99 POLL=30 \
       TASKPUMP_POOL_CAP_STALE_SEC=900 "$WATCHDOG" --once 2>&1)"
assert_no  "and a sane poll says nothing about it"                     "$out" "TASKPUMP_POOL_CAP_STALE_SEC"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ "$FAIL" -eq 0 ]]
