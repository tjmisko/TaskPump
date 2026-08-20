#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Tristan Misko
# test-tp-task-lock.sh — the cross-agent state lock's file, and its lifetime.
#
# The lock is an flock on a file in the ledger's git root, so the file is part
# of the consumer's tree whether they asked for it or not. Issue #33 caught the
# adoption shape: `tp init` then three `tp task create` calls, and the very
# first `git status` a new consumer runs carries `?? .taskpump-task.lock` —
# litter the tool made and never explained.
#
# Removing it is only half the requirement. The other half is that removal must
# not weaken the exclusion the file exists to provide: unlink the wrong inode
# and two agents hold two different locks while both believe they are alone,
# which is the claim race this lock was added to close. So the cases below come
# in two halves — the file does not outlive the verb, AND a verb that could not
# take the lock neither runs nor disturbs the holder's file.
#
# These fixtures deliberately do NOT set TASKPUMP_TASK_NOCOMMIT=1: that switch
# disables the state lock entirely (tp-task's acquire_state_lock returns early
# on it), so a suite that sets it globally cannot see this file at all.
#
# Run: ./tests/test-tp-task-lock.sh
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
CLI="$TP_ROOT/libexec/tp-task"
TP="$TP_ROOT/bin/tp"

# Hermeticity: ignore any taskpump.conf above $PWD and scrub inherited
# TASKPUMP_*/TP_*/ARACHNE_* (issue #18). run-all.sh sources the same prologue;
# this covers standalone runs.
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
have() { grep -qF -- "$2" <<<"$1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

summary() {
  echo
  echo "=============================================="
  echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
  echo "=============================================="
  [[ $FAIL -eq 0 ]] || exit 1
}

# Both halves of the lock's contract are host-conditional, and where they
# degrade they degrade to *documented* behavior rather than to a wrong answer:
# without flock there is no lock at all (a stock macOS host), and without a
# /proc that names an open file there is no way to prove the path still holds
# the inode we locked, so tp-task keeps the file rather than risk unlinking
# another agent's. Assert neither on a host that has neither.
if ! command -v flock >/dev/null 2>&1; then
  echo "SKIP: flock is unavailable here; the state lock is a documented no-op"
  summary
  exit 0
fi
if [[ ! -d /proc/self/fd ]]; then
  echo "SKIP: no /proc/self/fd here; lockfile removal is disabled by design"
  summary
  exit 0
fi

LOCK_NAME=.taskpump-task.lock

# A scratch consumer ledger: a git repository with a tasks dir and one commit,
# so `git status --porcelain` answers about this suite's changes only.
mkledger() {  # mkledger <name> -> prints the repo root
  local root="$TMP/$1"
  mkdir -p "$root/tasks"
  git -C "$root" -c init.defaultBranch=main init -q
  git -C "$root" -c user.name=t -c user.email=t@e commit -q --allow-empty -m "initial"
  printf '%s\n' "$root"
}

# A mutating verb, run the way an agent runs it: committing ON, so the state
# lock is live. Diagnostics stay on the suite's stderr unless a case captures
# them itself.
task_in() {  # task_in <ledger-root> <args...>
  local root=$1; shift
  env TASKPUMP_TASKS_DIR="$root/tasks" "$CLI" "$@"
}

# Wait (bounded) for a background holder to say it has the lock. Polling beats
# a fixed sleep: a loaded CI box is slow, and a fast one should not pay for it.
await() {  # await <marker-file>
  local i
  for (( i = 0; i < 100; i++ )); do
    [[ -e "$1" ]] && return 0
    sleep 0.05
  done
  return 1
}

# Another agent, holding the lock on <lockfile> until killed. `unlinked` makes
# it hold an inode that has left the tree — the state a departing agent leaves
# behind for the instant between its unlink and its exit, and the one shape
# that must never make a later agent wait forever.
#
# Its stdout and stderr go to /dev/null deliberately: run-all.sh captures a
# suite with `out="$(bash "$suite" 2>&1)"`, and a background process holding
# that pipe open would stall the whole run until it exits, however the case
# that started it ended.
HOLDER_PID=""
hold_lock() {  # hold_lock <lockfile> [unlinked]
  local lockfile=$1 unlinked=${2:-} marker="$TMP/held.$$"
  rm -f -- "$marker"
  bash -c '
    exec 9>"$1"
    flock 9 || exit 1
    [[ -n "$3" ]] && rm -f -- "$1"
    : >"$2"
    sleep 30
  ' _ "$lockfile" "$marker" "$unlinked" >/dev/null 2>&1 &
  HOLDER_PID=$!
  await "$marker" || { fail "the background lock holder never started"; return 1; }
}

release_holder() {
  [[ -n "$HOLDER_PID" ]] || return 0
  kill "$HOLDER_PID" 2>/dev/null || true
  wait "$HOLDER_PID" 2>/dev/null || true
  HOLDER_PID=""
}

# ── Half one: the lockfile does not outlive the verb that took it ────────────
echo "--- the state lockfile does not outlive the verb ---"

L1=$(mkledger clean)
out=$(task_in "$L1" create T1 --title "First" --goal "done looks like this" 2>&1); rc=$?
[[ $rc -eq 0 ]] || fail "create failed: $out"
[[ ! -e "$L1/$LOCK_NAME" ]] \
  && pass "should remove the state lockfile when a mutating verb exits cleanly" \
  || fail "should remove the state lockfile when a mutating verb exits cleanly — $LOCK_NAME survived"

status=$(git -C "$L1" status --porcelain)
have "$status" "$LOCK_NAME" \
  && fail "should leave no untracked lockfile in git status when a task is created — status:\n$status" \
  || pass "should leave no untracked lockfile in git status when a task is created"

# The die path. `create` takes the lock BEFORE its exists-check, so a duplicate
# id ends at die() without ever reaching the bottom of main(): an inline
# cleanup at the end of the dispatch would miss exactly this, and every other
# refusal with it.
set +e
out=$(task_in "$L1" create T1 --title "Again" --goal "duplicate" 2>&1)
rc=$?
set -e
[[ $rc -eq 1 ]] && pass "a duplicate id still exits 1" || fail "duplicate create exited $rc: $out"
[[ ! -e "$L1/$LOCK_NAME" ]] \
  && pass "should remove the state lockfile when the verb dies with a refusal" \
  || fail "should remove the state lockfile when the verb dies with a refusal — $LOCK_NAME survived"

# The deliberate non-zero exit. fsck --fix takes the lock and returns 3 when
# violations remain; 3 is a verdict, not a crash, and it must clean up too.
L2=$(mkledger fsck)
printf -- '---\nid: T99\ntitle: Wrong stem\n---\n\n# stem says T5\n' >| "$L2/tasks/T5.md"
set +e
out=$(task_in "$L2" fsck --fix 2>&1)
rc=$?
set -e
[[ $rc -eq 3 ]] && pass "fsck --fix still exits 3 over an unfixable violation" \
  || fail "fsck --fix exited $rc: $out"
[[ ! -e "$L2/$LOCK_NAME" ]] \
  && pass "should remove the state lockfile when fsck --fix exits 3" \
  || fail "should remove the state lockfile when fsck --fix exits 3 — $LOCK_NAME survived"

# The name is the consumer's to choose (TASKPUMP_LOCK_NAME); removal must
# follow the configured name, not a baked one.
L3=$(mkledger renamed)
out=$(env TASKPUMP_LOCK_NAME=.my-ledger.lock TASKPUMP_TASKS_DIR="$L3/tasks" \
      "$CLI" create T1 --title "Renamed" --goal "g" 2>&1); rc=$?
[[ $rc -eq 0 ]] || fail "create under a pinned lock name failed: $out"
[[ ! -e "$L3/.my-ledger.lock" ]] \
  && pass "should remove the lockfile the consumer named when TASKPUMP_LOCK_NAME is pinned" \
  || fail "should remove the lockfile the consumer named when TASKPUMP_LOCK_NAME is pinned — .my-ledger.lock survived"

# A read-only verb never takes the lock, so it has nothing to remove — and must
# leave nothing behind either. Its own ledger, so the answer is about `list`
# and not about whichever verb ran before it.
L_RO=$(mkledger readonly)
out=$(task_in "$L_RO" list 2>&1) || fail "list failed: $out"
[[ ! -e "$L_RO/$LOCK_NAME" ]] \
  && pass "should create no lockfile when a read-only verb runs" \
  || fail "should create no lockfile when a read-only verb runs — list left $LOCK_NAME"

# ── The adoption repro from issue #33, end to end ────────────────────────────
echo
echo "--- a new consumer's first git status (issue #33) ---"

ADOPT=$(mkledger adopt)
rmdir "$ADOPT/tasks"                     # let init scaffold it, as a consumer would
out=$( cd "$ADOPT" && env TASKPUMP_NO_CONF=0 "$TP" init 2>&1 ); rc=$?
[[ $rc -eq 0 ]] || fail "tp init failed: $out"
for id in T1 T2 T3; do
  out=$( cd "$ADOPT" && env TASKPUMP_NO_CONF=0 "$TP" task create "$id" --title "x" --goal "y" 2>&1 ) \
    || fail "create $id failed: $out"
done
status=$(git -C "$ADOPT" status --porcelain)
have "$status" "$LOCK_NAME" \
  && fail "should leave a scaffolded consumer's git status free of the lockfile when tp task create runs — status:\n$status" \
  || pass "should leave a scaffolded consumer's git status free of the lockfile when tp task create runs"
have "$status" 'taskpump.conf' \
  && pass "and still leaves the conf init announced" \
  || fail "the scaffolded conf went missing; status:\n$status"

# ── Half two: removal must not weaken the exclusion ──────────────────────────
echo
echo "--- a verb that could not take the lock touches nothing ---"

L4=$(mkledger contended)
# `|| true`: a holder that never came up has already registered its own FAIL,
# and this suite says more by running the rest of the cases than by aborting.
hold_lock "$L4/$LOCK_NAME" || true
set +e
out=$(env TASKPUMP_LOCK_WAIT=1 TASKPUMP_TASKS_DIR="$L4/tasks" \
      "$CLI" create T1 --title "Contended" --goal "g" 2>&1)
rc=$?
set -e
[[ $rc -eq 1 ]] && pass "should exit 1 when another agent holds the state lock" \
  || fail "should exit 1 when another agent holds the state lock — exited $rc: $out"
have "$out" 'could not acquire state lock' \
  && pass "should name the lock it could not take when it gives up" \
  || fail "should name the lock it could not take when it gives up — said: $out"
[[ -e "$L4/$LOCK_NAME" ]] \
  && pass "should leave the holder's lockfile in place when it could not take the lock" \
  || fail "should leave the holder's lockfile in place when it could not take the lock — it was removed"
[[ ! -e "$L4/tasks/T1.md" ]] \
  && pass "should write no task when it could not take the lock" \
  || fail "should write no task when it could not take the lock — T1.md exists"
release_holder

# A holder whose file has already left the tree holds an flock nothing else
# will ever open. It excludes nobody, so the next agent must take the file that
# is actually at the path and get on with it — never inherit the dead inode,
# and never wait out TASKPUMP_LOCK_WAIT for a lock that cannot be released to
# it.
L5=$(mkledger departed)
hold_lock "$L5/$LOCK_NAME" unlinked || true
set +e
out=$(env TASKPUMP_LOCK_WAIT=5 TASKPUMP_TASKS_DIR="$L5/tasks" \
      "$CLI" create T1 --title "After a departure" --goal "g" 2>&1)
rc=$?
set -e
[[ $rc -eq 0 ]] \
  && pass "should acquire on a fresh lockfile when a departed agent still holds the unlinked one" \
  || fail "should acquire on a fresh lockfile when a departed agent still holds the unlinked one — exited $rc: $out"
[[ -f "$L5/tasks/T1.md" ]] && pass "and the task it was asked for exists" \
  || fail "T1.md was not written: $out"
[[ ! -e "$L5/$LOCK_NAME" ]] \
  && pass "and it removed the lockfile it actually held" \
  || fail "the fresh lockfile survived the exit"
release_holder

# ── The drain shape: every departure removes the file the next agent is on ───
# A dozen agents mutate one ledger at once, and each one now unlinks the
# lockfile as it leaves — so the waiter behind it wakes on an inode that has
# already left the tree and has to re-queue on the file that replaced it. A
# fixed retry count turns that into refusals under exactly the load the lock
# was built for (an early cut of this fix failed seven of ten agents), so the
# case is here permanently: contention may make an agent wait, never lose.
echo
echo "--- a drain's worth of agents on one ledger ---"

L6=$(mkledger drain)
LOG="$TMP/drain.log"
: >| "$LOG"
set +e
for id in T1 T2 T3 T4 T5 T6 T7 T8; do
  env TASKPUMP_LOCK_WAIT=60 TASKPUMP_TASKS_DIR="$L6/tasks" \
    "$CLI" create "$id" --title "concurrent $id" --goal g >>"$LOG" 2>&1 &
done
wait
set -e
made=$(find "$L6/tasks" -name '*.md' | wc -l)
[[ "$made" -eq 8 ]] \
  && pass "should admit every concurrent agent when each removes its lockfile on exit" \
  || fail "should admit every concurrent agent when each removes its lockfile on exit — $made of 8 tasks written:\n$(cat "$LOG")"
[[ ! -e "$L6/$LOCK_NAME" ]] \
  && pass "and the last agent out leaves no lockfile behind" \
  || fail "and the last agent out leaves no lockfile behind — $LOCK_NAME survived"

# The claim race itself: eight agents filing the SAME id. Exactly one may win,
# and the losers must be refused by the exists-check rather than truncate the
# winner's file — that is what the lock is for, and removal must not cost it.
: >| "$LOG"
set +e
for _ in 1 2 3 4 5 6 7 8; do
  env TASKPUMP_LOCK_WAIT=60 TASKPUMP_TASKS_DIR="$L6/tasks" \
    "$CLI" create T99 --title "race" --goal g >>"$LOG" 2>&1 &
done
wait
set -e
won=$(grep -c '^created T99' "$LOG" || true)
lost=$(grep -c 'task already exists: T99' "$LOG" || true)
[[ "$won" -eq 1 && "$lost" -eq 7 ]] \
  && pass "should let exactly one agent create an id when eight file it at once" \
  || fail "should let exactly one agent create an id when eight file it at once — $won created, $lost refused:\n$(cat "$LOG")"

summary
