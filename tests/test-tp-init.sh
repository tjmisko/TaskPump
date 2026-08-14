#!/usr/bin/env bash
# test-tp-init.sh — tp init scaffolds a new consumer (G4.1).
#
# The contract under test:
#
#   * fresh repo: one command writes a commented taskpump.conf at the worktree
#     root and creates the tasks directory, and the quickstart continues from
#     there — `tp task create` lands in the freshly scaffolded ledger and
#     `tp task ready` sees it, with no further configuration;
#   * the conf carries ONLY the keys a starter decides (TASKPUMP_TASKS_DIR,
#     TASKPUMP_ID_PATTERN, a commented TASKPUMP_BUILD_GATE) plus a pointer to
#     taskpump.conf.example;
#   * a second run is an idempotent refusal: non-zero, names the existing
#     conf, changes nothing (asserted by diff);
#   * init from a subdirectory writes at the worktree root, not $PWD;
#   * existing state is never clobbered or silently adopted: a conf anywhere
#     the discovery walk would find one, a non-empty target directory, and a
#     --tasks-dir that would shadow a default-location ledger all refuse
#     loudly and leave the tree untouched.
#
# Hermetic: every fixture is a temp-dir git repo; no docker, no network, and
# nothing here touches any real ledger.
#
# Run: ./tests/test-tp-init.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TP="$TP_ROOT/bin/tp"
INIT="$TP_ROOT/libexec/tp-init"

# Hermeticity: ignore any taskpump.conf in the repo this suite happens to run
# from. tp-init itself never loads config (its refusal check consults the
# discovery walk directly, which the switch deliberately does not suppress),
# but the end-to-end create/ready calls below do — they opt back in with
# TASKPUMP_NO_CONF=0 per invocation, exactly like test-conf-hermeticity.sh.
export TASKPUMP_NO_CONF=1
unset CDPATH

# Clear both spellings of every ledger key an operator might have exported, so
# nothing can pre-satisfy (or break) a fixture invocation below.
for _suffix in TASKS_DIR TASK_OUT CODE_REPO TASK_PUSH PUSH TASK_NOCOMMIT \
               TASK_DEBUG LEDGER_PROBE TASKS_SUBDIR LEDGER_REPO ID_PATTERN \
               PHASE_SIGIL PROG_NAME TASK_EXT CONFIG; do
  unset "ARACHNE_$_suffix" "TASKPUMP_$_suffix" 2>/dev/null || true
done
unset _suffix

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
have() { grep -qE "$2" <<<"$1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

mkrepo() {  # mkrepo <path>
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" -c user.name=test -c user.email=t@e commit --allow-empty -q -m init
}

echo "--- fresh repo: the scaffold ---"

R1="$TMP/fresh"; mkrepo "$R1"
out=$( cd "$R1" && "$TP" init 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && pass "init exits 0 in a fresh repo" || fail "init rc=$rc:\n$out"
[[ -f "$R1/taskpump.conf" ]] && pass "taskpump.conf written at the worktree root" \
  || fail "no taskpump.conf at $R1"
[[ -d "$R1/tasks" ]] && pass "the tasks directory was created" || fail "no tasks dir at $R1"

grep -q '^TASKPUMP_TASKS_DIR=tasks$' "$R1/taskpump.conf" \
  && pass "conf sets TASKPUMP_TASKS_DIR=tasks" || fail "no TASKPUMP_TASKS_DIR line"
grep -q '^TASKPUMP_ID_PATTERN=' "$R1/taskpump.conf" \
  && pass "conf sets TASKPUMP_ID_PATTERN" || fail "no TASKPUMP_ID_PATTERN line"
grep -q '^# TASKPUMP_BUILD_GATE=' "$R1/taskpump.conf" \
  && pass "TASKPUMP_BUILD_GATE is present but commented" || fail "no commented build gate"
grep -q 'taskpump.conf.example' "$R1/taskpump.conf" \
  && pass "conf points at taskpump.conf.example for the census" \
  || fail "no pointer to taskpump.conf.example"

# Only the starter's keys are actually SET — everything else stays commentary.
got=$(grep -c '^TASKPUMP_' "$R1/taskpump.conf")
[[ "$got" == "2" ]] && pass "exactly two keys are uncommented (tasks dir, id pattern)" \
  || fail "expected 2 uncommented keys, found $got"

have "$out" 'tp task create' && pass "prints the next command: tp task create" \
  || fail "no 'tp task create' in output:\n$out"
have "$out" 'tp task ready' && pass "prints the next command: tp task ready" \
  || fail "no 'tp task ready' in output:\n$out"
have "$out" 'tp pump .*--dry-run' && pass "prints the next command: tp pump --dry-run" \
  || fail "no 'tp pump --dry-run' in output:\n$out"

out=$("$TP" help)
have "$out" '^  init ' && pass "tp help lists init" || fail "init missing from tp help"

echo
echo "--- the quickstart continues: create and ready in the scaffolded repo ---"

out=$( cd "$R1" && env TASKPUMP_NO_CONF=0 "$TP" task create T1 \
        --title "First task" --goal "The scaffold works end to end." 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && pass "tp task create works with no further configuration" \
  || fail "create rc=$rc:\n$out"
[[ -f "$R1/tasks/T1.md" ]] && pass "the task landed in the scaffolded ledger" \
  || fail "no $R1/tasks/T1.md; create said:\n$out"
grep -qE '^id: "?T1"?$' "$R1/tasks/T1.md" && pass "the task file carries its id" \
  || fail "no 'id: T1' in T1.md"

got=$( cd "$R1" && env TASKPUMP_NO_CONF=0 "$TP" task ready --count 2>/dev/null )
[[ "$got" == "1" ]] && pass "tp task ready --count sees the new task" \
  || fail "ready --count got '$got', expected 1"

got=$(git -C "$R1" log -1 --format=%s)
[[ "$got" == "create T1" ]] && pass "the ledger commit landed in the scratch repo, not elsewhere" \
  || fail "HEAD commit is '$got', expected 'create T1'"

echo
echo "--- re-run: idempotent refusal, tree unchanged ---"

R2="$TMP/rerun"; mkrepo "$R2"
( cd "$R2" && "$TP" init >/dev/null 2>&1 )
cp -a "$R2" "$TMP/rerun.before"
out=$( cd "$R2" && "$TP" init 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && pass "second init exits non-zero" || fail "second init exited 0"
have "$out" "$R2/taskpump.conf" && pass "the refusal names the existing conf" \
  || fail "refusal does not name $R2/taskpump.conf:\n$out"
have "$out" 'already initialized' && pass "the refusal says the repo is already initialized" \
  || fail "no 'already initialized' in:\n$out"
if diff -r "$R2" "$TMP/rerun.before" >/dev/null 2>&1; then
  pass "the second run changed nothing (diff -r clean)"
else
  fail "second init changed the tree:\n$(diff -r "$R2" "$TMP/rerun.before" 2>&1)"
fi

echo
echo "--- subdirectory: the conf goes to the worktree root, not \$PWD ---"

R3="$TMP/subdir"; mkrepo "$R3"; mkdir -p "$R3/src/deep"
out=$( cd "$R3/src/deep" && "$TP" init 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && pass "init from a subdirectory exits 0" || fail "subdir init rc=$rc:\n$out"
[[ -f "$R3/taskpump.conf" ]] && pass "conf written at the root" || fail "no conf at $R3"
[[ ! -e "$R3/src/deep/taskpump.conf" ]] && pass "no conf in \$PWD" \
  || fail "a conf was written into the subdirectory"
[[ -d "$R3/tasks" ]] && pass "tasks dir created at the root" || fail "no tasks dir at $R3"

out=$( cd "$R3/src/deep" && "$TP" init 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && have "$out" "$R3/taskpump.conf" \
  && pass "re-run from the subdirectory still finds and names the root conf" \
  || fail "subdir re-run rc=$rc, output:\n$out"

echo
echo "--- --tasks-dir ---"

R4="$TMP/elsewhere"; mkrepo "$R4"
out=$( cd "$R4" && "$TP" init --tasks-dir planning/tasks 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && pass "init --tasks-dir exits 0" || fail "rc=$rc:\n$out"
[[ -d "$R4/planning/tasks" ]] && pass "the named directory was created" \
  || fail "no $R4/planning/tasks"
grep -q '^TASKPUMP_TASKS_DIR=planning/tasks$' "$R4/taskpump.conf" \
  && pass "conf records the chosen tasks dir" || fail "conf does not carry planning/tasks"
[[ ! -d "$R4/tasks" ]] && pass "no default tasks dir alongside the chosen one" \
  || fail "a default tasks/ was also created"

out=$( cd "$R4" && env TASKPUMP_NO_CONF=0 "$TP" task create T1 \
        --title "Elsewhere" --goal "The chosen ledger is the one used." 2>&1 ); rc=$?
[[ $rc -eq 0 && -f "$R4/planning/tasks/T1.md" ]] \
  && pass "create lands in the chosen ledger" \
  || fail "create rc=$rc; planning/tasks/T1.md exists: $(test -f "$R4/planning/tasks/T1.md" && echo yes || echo no):\n$out"

echo
echo "--- clobber refusals: existing state is never overwritten or adopted ---"

# A hand-written conf the walk finds: refuse, name it, leave it byte-identical.
R5="$TMP/hasconf"; mkrepo "$R5"
printf '# hand-written\nTASKPUMP_PHASE_SIGIL=J\n' > "$R5/taskpump.conf"
cp "$R5/taskpump.conf" "$TMP/hasconf.conf.before"
out=$( cd "$R5" && "$TP" init 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && pass "an existing conf refuses" || fail "init overwrote past a conf (rc=0)"
have "$out" "$R5/taskpump.conf" && pass "the refusal names the conf path" \
  || fail "refusal does not name the conf:\n$out"
cmp -s "$R5/taskpump.conf" "$TMP/hasconf.conf.before" \
  && pass "the existing conf is byte-identical after the refusal" \
  || fail "the existing conf was modified"
[[ ! -d "$R5/tasks" ]] && pass "no tasks dir was created on the refusal path" \
  || fail "a tasks dir appeared despite the refusal"

# A conf in a subdirectory between $PWD and the root — the discovery walk finds
# it first, so init must not shadow it with a second conf at the root.
R6="$TMP/vendored"; mkrepo "$R6"; mkdir -p "$R6/vendor"
printf 'TASKPUMP_TASKS_DIR=vt\n' > "$R6/vendor/taskpump.conf"
out=$( cd "$R6/vendor" && "$TP" init 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && pass "a conf anywhere the walk finds one refuses" \
  || fail "init ran despite a discoverable conf"
have "$out" "$R6/vendor/taskpump.conf" && pass "the refusal names the discovered conf" \
  || fail "refusal does not name vendor/taskpump.conf:\n$out"
[[ ! -e "$R6/taskpump.conf" ]] && pass "no root conf was written over the discovered one" \
  || fail "a root conf appeared"

# A non-empty tasks directory is an existing ledger: never adopt it.
R7="$TMP/bare"; mkrepo "$R7"; mkdir -p "$R7/tasks"
printf -- '---\nid: T1\n---\n' > "$R7/tasks/T1.md"
out=$( cd "$R7" && "$TP" init 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && pass "a non-empty tasks dir refuses" || fail "init adopted an existing ledger"
have "$out" "$R7/tasks" && pass "the refusal names the existing ledger dir" \
  || fail "refusal does not name the dir:\n$out"
[[ ! -e "$R7/taskpump.conf" ]] && pass "no conf written beside an existing ledger" \
  || fail "a conf appeared despite the refusal"

# An EMPTY pre-made tasks dir is the quickstart's own `mkdir tasks` — proceed.
R8="$TMP/premade"; mkrepo "$R8"; mkdir -p "$R8/tasks"
out=$( cd "$R8" && "$TP" init 2>&1 ); rc=$?
[[ $rc -eq 0 && -f "$R8/taskpump.conf" ]] \
  && pass "an empty pre-made tasks dir is fine (mkdir-first quickstart)" \
  || fail "rc=$rc with an empty tasks dir:\n$out"

# --tasks-dir elsewhere while a default-location ledger dir exists: the conf
# would shadow it. Refuse.
R9="$TMP/shadow"; mkrepo "$R9"; mkdir -p "$R9/tasks"
out=$( cd "$R9" && "$TP" init --tasks-dir other/tasks 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && pass "--tasks-dir beside an existing default ledger dir refuses" \
  || fail "init shadowed $R9/tasks (rc=0)"
have "$out" "$R9/tasks" && pass "the shadow refusal names the existing dir" \
  || fail "refusal does not name it:\n$out"
[[ ! -e "$R9/taskpump.conf" && ! -d "$R9/other" ]] \
  && pass "the shadow refusal changed nothing" || fail "the refusal left state behind"

# Outside any git repository there is no worktree root to anchor at.
NOREPO="$TMP/norepo"; mkdir -p "$NOREPO"
out=$( cd "$NOREPO" && "$INIT" 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && pass "outside a git repository init refuses" || fail "init ran outside a repo"
have "$out" 'git' && pass "the refusal names the fix (a git repository)" \
  || fail "no mention of git in:\n$out"
[[ ! -e "$NOREPO/taskpump.conf" ]] && pass "nothing written outside a repo" \
  || fail "a conf appeared outside a repo"

echo
echo "--- usage errors ---"

R10="$TMP/usage"; mkrepo "$R10"
out=$( cd "$R10" && "$TP" init --bogus 2>&1 ); rc=$?
[[ $rc -eq 2 ]] && pass "an unknown flag exits 2" || fail "unknown flag rc=$rc"
out=$( cd "$R10" && "$TP" init --tasks-dir /abs/path 2>&1 ); rc=$?
[[ $rc -eq 2 ]] && pass "an absolute --tasks-dir exits 2" || fail "absolute path rc=$rc"
have "$out" 'relative' && pass "the absolute-path error explains the rule" \
  || fail "no explanation:\n$out"
out=$( cd "$R10" && "$TP" init --tasks-dir '../out' 2>&1 ); rc=$?
[[ $rc -eq 2 ]] && pass "a --tasks-dir escaping the repo exits 2" || fail "../ rc=$rc"
[[ ! -e "$R10/taskpump.conf" ]] && pass "usage errors write nothing" \
  || fail "a usage error still wrote a conf"
out=$( cd "$R10" && "$TP" init --help 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && have "$out" 'tasks-dir' && pass "--help exits 0 and documents --tasks-dir" \
  || fail "--help rc=$rc:\n$out"

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
