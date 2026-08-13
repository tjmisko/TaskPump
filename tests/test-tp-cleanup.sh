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

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ "$FAIL" -eq 0 ]]
