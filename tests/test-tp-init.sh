#!/usr/bin/env bash
# test-tp-init.sh — `tp init` scaffolds a new consumer (G4.1).
#
# Three things are being pinned here, and they pull in opposite directions:
#
#   * the scaffold WORKS — a scratch repository goes init → create → ready with
#     no further configuration, from its root AND from a subdirectory;
#   * the scaffold LANDS AT THE WORKTREE ROOT, because that is the only
#     directory from which a conf governs the whole repository;
#   * the scaffold REFUSES when a conf is already discoverable, and a refusal
#     changes nothing — asserted by diffing the tree against a copy taken
#     before the refusal, not by spot-checking a file.
#
# Hermeticity note: this suite's subject IS config discovery, so most cases have
# to opt back INTO the walk that run-all.sh turns off. Every invocation below
# therefore states its own TASKPUMP_NO_CONF; the export covers incidental calls
# and standalone runs. Nothing here ever runs with $PWD inside the TaskPump
# checkout — a scaffold that walked up from there would find TaskPump's own
# dogfood conf, and a case that wrote one would litter the repo (run-all.sh
# fails the run for that).
#
# Run: ./tests/test-tp-init.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
TP="$TP_ROOT/bin/tp"

export TASKPUMP_NO_CONF=1

# An operator's exported TaskPump settings must not pre-satisfy or break a case:
# the whole point of the end-to-end leg is that the generated conf alone is
# enough. Both spellings go, since the legacy one is promoted onto the canonical.
for _suffix in TASKS_DIR TASK_OUT CODE_REPO LEDGER_REPO LEDGER_PROBE TASKS_SUBDIR \
               TASK_PUSH PUSH TASK_NOCOMMIT TASK_DEBUG ID_PATTERN PHASE_SIGIL \
               PHASE_SEPARATOR TURN_BUDGET_DEFAULT COMMITTER_NAME COMMITTER_EMAIL \
               PROG_NAME CONFIG; do
  unset "ARACHNE_$_suffix" "TASKPUMP_$_suffix" 2>/dev/null || true
done
unset _suffix
unset ARACHNE_NO_CONF 2>/dev/null || true

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
have() { grep -qF -- "$2" <<<"$1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# A scratch consumer: a git repository, a source tree, no configuration at all.
mkrepo() {  # mkrepo <name> -> prints its path
  local root="$TMP/$1"
  mkdir -p "$root/src/deep"
  git -C "$root" -c init.defaultBranch=main init -q
  printf '%s\n' "$root"
}

# init, with discovery ON — the switch is a suite seam, and init's subject is
# the walk it turns off.
init_in() {  # init_in <cwd> [args...]
  local cwd=$1; shift
  ( cd "$cwd" && env TASKPUMP_NO_CONF=0 "$TP" init "$@" 2>&1 )
}

# A ledger verb run the way a new consumer would: from inside their repository,
# configured by nothing but the conf init just wrote. Diagnostics go to the
# suite's own stderr rather than into the captured value, so a case that parses
# output (jq, a count) can never be fed a warning line.
task_in() {  # task_in <cwd> <args...>
  local cwd=$1; shift
  ( cd "$cwd" && env TASKPUMP_NO_CONF=0 "$TP" task "$@" )
}

# The same, for the cases whose subject IS the diagnostic.
task_both_in() {  # task_both_in <cwd> <args...>
  local cwd=$1; shift
  ( cd "$cwd" && env TASKPUMP_NO_CONF=0 "$TP" task "$@" 2>&1 )
}

# ── The scaffold works, end to end, with no further configuration ─────────────
echo "--- a scratch repo goes init -> create -> ready ---"

REPO=$(mkrepo consumer)
out=$(init_in "$REPO"); rc=$?

[[ $rc -eq 0 ]] && pass "init exits 0 in a fresh repository" || fail "init rc=$rc:\n$out"
[[ -f "$REPO/taskpump.conf" ]] && pass "init wrote taskpump.conf at the repo root" \
  || fail "no taskpump.conf at $REPO"
[[ -d "$REPO/tasks" ]] && pass "init created the tasks directory" || fail "no tasks/ at $REPO"

# The printed continuation is part of the deliverable: a quickstart that stops
# at "now what?" has not started anybody.
have "$out" 'tp task create' && pass "it prints the create command" || fail "no create command:\n$out"
have "$out" 'tp task ready'  && pass "it prints the ready command"  || fail "no ready command:\n$out"
have "$out" '--dry-run'      && pass "it prints the pump dry-run command" || fail "no dry-run command:\n$out"

# Only the keys a starter decides, and the pointer to the census for the rest.
conf=$(cat "$REPO/taskpump.conf")
have "$conf" 'TASKPUMP_TASKS_DIR='  && pass "the conf sets the tasks dir" || fail "no TASKPUMP_TASKS_DIR:\n$conf"
# The loader anchors conf-relative paths (issue #1), so the scaffold writes the
# documented relative form — not an embedded cd workaround.
grep -qE "^TASKPUMP_TASKS_DIR='tasks'\$" "$REPO/taskpump.conf" \
  && pass "the tasks dir is the documented relative form" \
  || fail "the tasks-dir line is not the documented relative form:\n$conf"
have "$conf" 'CDPATH' \
  && fail "the conf still embeds the issue-#1 cd workaround:\n$conf" \
  || pass "no embedded cd workaround: the conf loader owns anchoring"
have "$conf" 'TASKPUMP_ID_PATTERN=' && pass "the conf sets the id pattern" || fail "no TASKPUMP_ID_PATTERN:\n$conf"
have "$conf" '# TASKPUMP_BUILD_GATE=' && pass "the build gate is present but commented out" \
  || fail "TASKPUMP_BUILD_GATE is not a commented key:\n$conf"
grep -qE '^TASKPUMP_BUILD_GATE=' "$REPO/taskpump.conf" \
  && fail "the build gate is live, not commented" \
  || pass "the build gate does not take effect until uncommented"
have "$conf" 'taskpump.conf.example' && pass "the conf points at the full key census" \
  || fail "no pointer to taskpump.conf.example:\n$conf"
# Two live keys and one commented one is the whole file: a starter conf that
# restates defaults it does not decide is a file nobody reads.
n=$(grep -cE '^[A-Za-z_]+=' "$REPO/taskpump.conf")
[[ "$n" -eq 2 ]] && pass "exactly the two live keys, nothing else uncommented" \
  || fail "the conf carries $n uncommented keys, expected 2"

# The end-to-end leg. Nothing below sets a TASKPUMP_* key: if the conf is not
# sufficient, these fail.
out=$(task_in "$REPO" create T1 --title "Parse the manifest" --goal "Manifests load."); rc=$?
[[ $rc -eq 0 ]] && pass "tp task create works against the scaffolded ledger" || fail "create rc=$rc:\n$out"
[[ -f "$REPO/tasks/T1.md" ]] && pass "the task landed in the scaffolded tasks dir" \
  || fail "no tasks/T1.md after create"

got=$(task_in "$REPO" ready --count)
[[ "$got" == "1" ]] && pass "tp task ready sees the new task" || fail "ready --count got '$got'"
got=$(task_in "$REPO" next --branch feat/t1 | jq -r .id)
[[ "$got" == "T1" ]] && pass "tp task next returns it" || fail "next got '$got'"

# The default id grammar the conf pins has to reject as well as accept, or the
# key is decoration.
out=$(task_both_in "$REPO" create Q9 --title "wrong grammar"); rc=$?
[[ $rc -ne 0 ]] && pass "the conf's id pattern rejects a foreign grammar" \
  || fail "create accepted Q9 under a T pattern"

# ── The same ledger from a subdirectory ──────────────────────────────────────
# A conf whose tasks dir resolves against $PWD answers "no open tasks" from any
# subdirectory, at rc 0 — a silent false drain (issue #1). A scaffold must not
# hand a new consumer that.
echo
echo "--- the scaffolded conf resolves the same ledger from a subdirectory ---"

got=$(task_in "$REPO/src/deep" ready --count)
[[ "$got" == "1" ]] && pass "ready --count from a subdirectory sees the same 1 task" \
  || fail "subdirectory ready --count got '$got', expected 1"
got=$(task_in "$REPO/src/deep" resolve --tasks-dir)
[[ "$got" == "$REPO/tasks" ]] && pass "resolve --tasks-dir from a subdirectory lands on the repo's ledger" \
  || fail "subdirectory resolve got '$got', expected $REPO/tasks"

# ── Refusing an existing conf, and changing nothing ──────────────────────────
echo
echo "--- a second init refuses, names the conf, and leaves the tree alone ---"

cp -a "$REPO" "$TMP/consumer.before"

out=$(init_in "$REPO"); rc=$?
[[ $rc -ne 0 ]] && pass "a second init exits non-zero" || fail "second init exited 0:\n$out"
have "$out" "$REPO/taskpump.conf" && pass "the refusal names the existing conf" \
  || fail "the refusal does not name the conf:\n$out"

d=$(diff -r -x .git "$TMP/consumer.before" "$REPO" 2>&1)
[[ -z "$d" ]] && pass "the refusal left the tree byte-identical" || fail "the refusal changed the tree:\n$d"

# Idempotent failure: the second refusal is the first one again, not an escalation.
out=$(init_in "$REPO"); rc=$?
[[ $rc -ne 0 ]] && pass "a third init refuses the same way" || fail "third init exited 0:\n$out"
d=$(diff -r -x .git "$TMP/consumer.before" "$REPO" 2>&1)
[[ -z "$d" ]] && pass "re-running after a refusal still changes nothing" || fail "the tree drifted:\n$d"

# A conf found part-way up the walk is somebody's ledger too: the refusal is
# about what discovery finds, not only about the file init was about to write.
NESTED=$(mkrepo nested)
mkdir -p "$NESTED/vendored/sub"
printf 'TASKPUMP_ID_PATTERN=%s\n' "'^V[0-9]+(\.[0-9]+)?\$'" >| "$NESTED/vendored/taskpump.conf"
out=$(init_in "$NESTED/vendored/sub"); rc=$?
[[ $rc -ne 0 ]] && pass "init refuses a conf discovered above \$PWD" || fail "init ignored an intermediate conf:\n$out"
have "$out" "$NESTED/vendored/taskpump.conf" && pass "the refusal names the intermediate conf" \
  || fail "refusal did not name the intermediate conf:\n$out"
[[ ! -e "$NESTED/taskpump.conf" ]] && pass "no conf was written at the root of the shadowed repo" \
  || fail "init wrote a conf despite refusing"

# An explicit TASKPUMP_CONFIG outranks the walk everywhere else in TaskPump, so
# it outranks it here: a named conf is the configuration this invocation would
# run under, and a scaffold must not shadow it either.
EXPLICIT=$(mkrepo explicit)
printf 'TASKPUMP_TASK_PUSH=0\n' >| "$TMP/elsewhere.conf"
out=$( cd "$EXPLICIT" && env TASKPUMP_NO_CONF=0 TASKPUMP_CONFIG="$TMP/elsewhere.conf" "$TP" init 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && pass "init refuses under an explicit TASKPUMP_CONFIG" || fail "init ran under TASKPUMP_CONFIG:\n$out"
have "$out" "$TMP/elsewhere.conf" && pass "the refusal names the explicitly configured file" \
  || fail "refusal did not name TASKPUMP_CONFIG's file:\n$out"
[[ ! -e "$EXPLICIT/taskpump.conf" ]] && pass "nothing was written under an explicit config" \
  || fail "init wrote a conf under TASKPUMP_CONFIG"

# The floor beneath discovery: with the walk switched off there is nothing to
# discover, and "nothing discovered" must never come to mean "overwrite what is
# already on disk".
SWITCHED=$(mkrepo switched)
out=$(init_in "$SWITCHED"); rc=$?
[[ $rc -eq 0 ]] || fail "setup init failed:\n$out"
before=$(cat "$SWITCHED/taskpump.conf")
out=$( cd "$SWITCHED" && env TASKPUMP_NO_CONF=1 "$TP" init 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && pass "init refuses an existing conf even with discovery off" \
  || fail "init overwrote a conf under TASKPUMP_NO_CONF=1:\n$out"
[[ "$(cat "$SWITCHED/taskpump.conf")" == "$before" ]] && pass "the existing conf is untouched" \
  || fail "the conf changed under TASKPUMP_NO_CONF=1"

# ── The conf lands at the worktree root, not at $PWD ─────────────────────────
echo
echo "--- init from a subdirectory writes at the worktree root ---"

DEEP=$(mkrepo deep)
out=$(init_in "$DEEP/src/deep"); rc=$?
[[ $rc -eq 0 ]] && pass "init exits 0 from a subdirectory" || fail "init rc=$rc from a subdirectory:\n$out"
[[ -f "$DEEP/taskpump.conf" ]] && pass "the conf landed at the worktree root" || fail "no conf at $DEEP"
[[ ! -e "$DEEP/src/deep/taskpump.conf" ]] && pass "no conf was written at \$PWD" \
  || fail "init wrote a conf at \$PWD"
[[ -d "$DEEP/tasks" && ! -d "$DEEP/src/deep/tasks" ]] && pass "the tasks dir landed at the root too" \
  || fail "tasks dir placement wrong: root=$([[ -d "$DEEP/tasks" ]] && echo yes || echo no) pwd=$([[ -d "$DEEP/src/deep/tasks" ]] && echo yes || echo no)"
have "$out" "$DEEP" && pass "the output names the root it scaffolded" || fail "output does not name the root:\n$out"

# A linked worktree is its own workspace with its own root — the wrong-ledger
# lesson in the shape init has to get right.
git -C "$DEEP" -c user.name=t -c user.email=t@e commit -q --allow-empty -m init
git -C "$DEEP" worktree add -q -b feat/wt "$TMP/deep-wt" >/dev/null 2>&1
if [[ -d "$TMP/deep-wt" ]]; then
  mkdir -p "$TMP/deep-wt/src"
  out=$(init_in "$TMP/deep-wt/src"); rc=$?
  [[ $rc -eq 0 ]] && pass "init exits 0 inside a linked worktree" || fail "worktree init rc=$rc:\n$out"
  [[ -f "$TMP/deep-wt/taskpump.conf" ]] && pass "the conf landed at the linked worktree's own root" \
    || fail "no conf at the linked worktree root"
else
  fail "could not create a linked worktree fixture"
fi

# ── --tasks-dir ──────────────────────────────────────────────────────────────
echo
echo "--- --tasks-dir moves the ledger ---"

ELSEWHERE=$(mkrepo elsewhere)
out=$(init_in "$ELSEWHERE" --tasks-dir planning/tasks); rc=$?
[[ $rc -eq 0 ]] && pass "init --tasks-dir exits 0" || fail "init --tasks-dir rc=$rc:\n$out"
[[ -d "$ELSEWHERE/planning/tasks" ]] && pass "it creates the named tasks directory" \
  || fail "no planning/tasks at $ELSEWHERE"
[[ ! -d "$ELSEWHERE/tasks" ]] && pass "it does not also create the default one" \
  || fail "init created tasks/ as well as the override"
have "$(cat "$ELSEWHERE/taskpump.conf")" 'planning/tasks' && pass "the conf carries the override" \
  || fail "the conf does not mention planning/tasks"

out=$(task_in "$ELSEWHERE" create T2 --title "Ship it" --goal "It ships."); rc=$?
[[ $rc -eq 0 && -f "$ELSEWHERE/planning/tasks/T2.md" ]] \
  && pass "create writes into the overridden ledger" || fail "create rc=$rc, no planning/tasks/T2.md:\n$out"
got=$(task_in "$ELSEWHERE/src/deep" ready --count)
[[ "$got" == "1" ]] && pass "the overridden ledger also resolves from a subdirectory" \
  || fail "subdirectory ready --count got '$got' with an overridden tasks dir"

EQFORM=$(mkrepo eqform)
out=$(init_in "$EQFORM" --tasks-dir=ledger); rc=$?
[[ $rc -eq 0 && -d "$EQFORM/ledger" ]] && pass "the --tasks-dir=<d> spelling works too" \
  || fail "--tasks-dir=ledger rc=$rc:\n$out"

# ── Argument and environment errors ──────────────────────────────────────────
echo
echo "--- refusals that are not about an existing conf ---"

BAD=$(mkrepo bad)
for arg in "../evil" "" "with space" "\$(touch $TMP/pwned)"; do
  out=$( cd "$BAD" && env TASKPUMP_NO_CONF=0 "$TP" init --tasks-dir "$arg" 2>&1 ); rc=$?
  [[ $rc -eq 2 ]] && pass "--tasks-dir '$arg' is a usage error (rc 2)" \
    || fail "--tasks-dir '$arg' exited $rc:\n$out"
done
[[ ! -e "$TMP/pwned" ]] && pass "a command-substitution tasks dir never reached a shell" \
  || fail "--tasks-dir executed its argument"
[[ ! -e "$BAD/taskpump.conf" ]] && pass "a rejected argument writes no conf" \
  || fail "init wrote a conf despite a bad argument"

out=$( cd "$BAD" && env TASKPUMP_NO_CONF=0 "$TP" init --bogus 2>&1 ); rc=$?
[[ $rc -eq 2 ]] && pass "an unknown argument is a usage error (rc 2)" || fail "--bogus exited $rc:\n$out"

out=$( cd "$BAD" && env TASKPUMP_NO_CONF=0 "$TP" init --tasks-dir 2>&1 ); rc=$?
[[ $rc -eq 2 ]] && pass "--tasks-dir with no value is a usage error (rc 2)" \
  || fail "bare --tasks-dir exited $rc:\n$out"

PLAIN="$TMP/not-a-repo"; mkdir -p "$PLAIN"
out=$( cd "$PLAIN" && env TASKPUMP_NO_CONF=0 "$TP" init 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && pass "init refuses outside a git repository" || fail "init ran outside a repo:\n$out"
have "$out" 'git' && pass "the refusal says a repository is what is missing" \
  || fail "the refusal does not mention git:\n$out"
[[ ! -e "$PLAIN/taskpump.conf" ]] && pass "nothing was written outside a repository" \
  || fail "init wrote a conf outside a repository"

# ── Scaffolding only ─────────────────────────────────────────────────────────
# The scope line of G4.1: init prepares a repository, it does not start using
# it. A conf committed on the consumer's behalf is a commit they did not make.
echo
echo "--- init scaffolds and stops ---"

SCOPE=$(mkrepo scope)
git -C "$SCOPE" -c user.name=t -c user.email=t@e commit -q --allow-empty -m "initial"
head_before=$(git -C "$SCOPE" rev-parse HEAD)
out=$(init_in "$SCOPE"); rc=$?
[[ $rc -eq 0 ]] || fail "scope-case init rc=$rc:\n$out"

[[ "$(git -C "$SCOPE" rev-parse HEAD)" == "$head_before" ]] && pass "init makes no commit" \
  || fail "init moved HEAD"
status=$(git -C "$SCOPE" status --porcelain)
have "$status" '?? taskpump.conf' && pass "the conf is left untracked for the consumer to stage" \
  || fail "the conf is not untracked; status:\n$status"
[[ -z "$(git -C "$SCOPE" diff --cached --name-only)" ]] && pass "init stages nothing" \
  || fail "init left something staged"
[[ -z "$(find "$SCOPE/tasks" -mindepth 1 -print -quit)" ]] && pass "init creates no tasks" \
  || fail "init put files in the tasks dir"

# ── Dispatch and help ────────────────────────────────────────────────────────
echo
echo "--- dispatch and help ---"

out=$("$TP" help 2>&1)
have "$out" 'init' && pass "tp help lists init" || fail "tp help does not list init:\n$out"

out=$("$TP" init --help 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "tp init --help exits 0" || fail "init --help exited $rc"
have "$out" 'tp init --tasks-dir' && pass "the help shows the --tasks-dir form" \
  || fail "help does not document --tasks-dir:\n$out"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
