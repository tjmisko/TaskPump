#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Tristan Misko
# test-example-confs.sh — the example configurations must tell the truth
# (issues #4, #5, #8, #9).
#
# Examples are what new consumers copy, so a wrong annotation propagates into
# someone's unattended run. This suite makes the honesty mechanical:
#
#   * examples/arachne.conf annotates every key as either a restated default,
#     a load-bearing pin, or a computed default, each citing the source line
#     the default lives at. Every annotation is re-derived here from the cited
#     source file — a default flip that outdates an annotation fails this
#     suite instead of rotting silently, which is how issue #4 happened at the
#     G1.3 filename flip. Values are compared, never line numbers, so a
#     drifted citation line is a nuisance and a drifted value is a failure.
#   * the conf must not pin an entrypoint that cannot run the pre-flight hook
#     it also configures (issue #5).
#   * loading the conf must not silently widen the unflagged pool cap: the cap
#     in a real dry-run plan must equal the shipped default, and widening must
#     still work per invocation via --jobs (issue #8).
#   * runners/claude-docker/preflight-example.sh must land the merged agent
#     settings in TASKPUMP_CONTAINER_HOME, not a hardcoded /home/dev — proven
#     by running the hook against a fixture home with a stubbed iptables
#     (issue #9).
#   * examples/minimal.conf's restated defaults are re-derived the same way,
#     and taskpump.conf.example must set nothing at all when sourced.
#
# Hermetic: temp-dir fixtures, stubbed docker/iptables, no network, no
# container runtime.
#
# Run: ./tests/test-example-confs.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ARACHNE_CONF="$TP_ROOT/examples/arachne.conf"
MINIMAL_CONF="$TP_ROOT/examples/minimal.conf"
CENSUS_CONF="$TP_ROOT/taskpump.conf.example"
PREFLIGHT="$TP_ROOT/runners/claude-docker/preflight-example.sh"
PUMP="$TP_ROOT/libexec/tp-pump"

# Hermeticity: the tools discover taskpump.conf by walking up from $PWD; the
# only conf allowed into a fixture invocation is the one this suite passes
# explicitly via TASKPUMP_CONFIG, which outranks this switch. run-all.sh
# exports the same; this covers standalone runs.
# shellcheck source=tests/suite-prologue.sh
. "$SCRIPT_DIR/suite-prologue.sh"

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

[[ -f "$ARACHNE_CONF" ]] || { echo "FAIL: $ARACHNE_CONF missing" >&2; exit 1; }
[[ -f "$PREFLIGHT" ]]    || { echo "FAIL: $PREFLIGHT missing" >&2; exit 1; }

# ── Deriving a shipped default from source ────────────────────────────────────
# The conf's annotations cite the file their default is read in (tp-pump:168
# style). src_path maps the cited basename to the tree; extract_default finds
# the first ${KEY:-…} / ${KEY:=…} expansion of the key in that file and returns
# the innermost literal fallback. entrypoint.sh reads its keys through ep_first
# and then defaults the SHORT name (`: "${RO_PROBE_FILE:=…}"`), so the TASKPUMP_
# prefix is retried stripped there.

src_path() {  # src_path <cited-basename>
  case "$1" in
    tp-task|tp-pump|tp-monitor|tp-dag-render) printf '%s' "$TP_ROOT/libexec/$1" ;;
    pump-lib.sh)   printf '%s' "$TP_ROOT/lib/pump-lib.sh" ;;
    entrypoint.sh) printf '%s' "$TP_ROOT/runners/claude-docker/entrypoint.sh" ;;
    claude-usage|claude-token-fresh|disk-low|net-health) printf '%s' "$TP_ROOT/gates/$1" ;;
    *) return 1 ;;
  esac
}

extract_default() {  # extract_default <key> <source-file>  → innermost fallback
  local key="$1" src="$2" line frag out="" depth=0 i c
  line="$(grep -oE "\\\$\\{${key}(:-|:=)[^\"']*" "$src" | head -1)"
  if [[ -z "$line" && "$src" == */entrypoint.sh ]]; then
    line="$(grep -oE "\\\$\\{${key#TASKPUMP_}(:-|:=)[^\"']*" "$src" | head -1)"
  fi
  [[ -n "$line" ]] || return 1
  frag="${line#*:-}"
  [[ "$frag" == "$line" ]] && frag="${line#*:=}"
  for ((i = 0; i < ${#frag}; i++)); do
    c="${frag:i:1}"
    if [[ "$c" == "{" ]]; then depth=$((depth + 1)); fi
    if [[ "$c" == "}" ]]; then
      [[ "$depth" -eq 0 ]] && break
      depth=$((depth - 1))
    fi
    out+="$c"
  done
  # Unwrap ${FALLBACK_SPELLING:-literal} nests down to the literal.
  while [[ "$out" == '${'*'}' ]]; do
    out="${out#\$\{}"; out="${out%\}}"
    case "$out" in
      *:-*) out="${out#*:-}" ;;
      *:=*) out="${out#*:=}" ;;
      *) break ;;
    esac
  done
  # State-dir-anchored defaults compare by name; the conf's block comments own
  # the "relative to the state dir" caveat.
  printf '%s' "${out#\$STATE_DIR/}"
}

# ── examples/arachne.conf: every annotation, re-derived ───────────────────────
echo "--- arachne.conf: annotations verified against cited source ---"

N_DEFAULT=0; N_PIN=0; N_COMPUTED=0
while IFS= read -r conf_line; do
  [[ "$conf_line" =~ ^(TASKPUMP_[A-Z0-9_]+)=(.*)$ ]] || continue
  key="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"

  # Any Arachne-flavored value must be marked as a pin — the exact failure
  # class of issue #4 was thirteen .arachne-* values annotated "(default)".
  if [[ "$rest" == *[Aa]rachne* && "$rest" != *'# (pin'* ]]; then
    fail "$key: an Arachne-flavored value must carry a '# (pin; …)' annotation: $rest"
  fi

  [[ "$rest" == *'# ('* ]] || continue
  value="${rest%%#*}"
  # Trim trailing whitespace, then surrounding quotes.
  while [[ "$value" == *' ' || "$value" == *$'\t' ]]; do value="${value%?}"; done
  [[ "$value" == \'*\' ]] && { value="${value#\'}"; value="${value%\'}"; }
  [[ "$value" == \"*\" ]] && { value="${value#\"}"; value="${value%\"}"; }
  ann="${rest#*\# (}"; ann="${ann%)}"

  case "$ann" in
    "default — "*)
      kind=default; claimed=""; cite="${ann#default — }" ;;
    "pin; shipped default: "*" — "*)
      kind=pin
      claimed="${ann#pin; shipped default: }"
      cite="${claimed##* — }"; claimed="${claimed% — *}" ;;
    "computed default: "*" — "*)
      kind=computed; claimed=""; cite="${ann##* — }" ;;
    *)
      fail "$key: unparseable annotation '# ($ann)' — use '(default — file:line)', '(pin; shipped default: X — file:line)', or '(computed default: … — file:line)'"
      continue ;;
  esac

  cite_file="${cite%%:*}"
  if ! src="$(src_path "$cite_file")" || [[ ! -f "$src" ]]; then
    fail "$key: annotation cites unknown source '$cite'"
    continue
  fi

  if [[ "$kind" == computed ]]; then
    if grep -q "$key\|${key#TASKPUMP_}" "$src"; then
      pass "$key: computed default — $cite_file reads the key"
    else
      fail "$key: computed-default annotation cites $cite_file, which never reads it"
    fi
    N_COMPUTED=$((N_COMPUTED + 1))
    continue
  fi

  if ! shipped="$(extract_default "$key" "$src")"; then
    fail "$key: no \${$key:-…} default found in $cite_file (annotation cites $cite)"
    continue
  fi

  if [[ "$kind" == default ]]; then
    N_DEFAULT=$((N_DEFAULT + 1))
    if [[ "$value" == "$shipped" ]]; then
      pass "$key=$value restates the shipped default ($cite_file)"
    else
      fail "$key: annotated '(default)' but the shipped default in $cite_file is '$shipped', not '$value' — re-annotate as a pin or fix the value"
    fi
  else
    N_PIN=$((N_PIN + 1))
    [[ "$claimed" == "none" ]] && claimed=""
    if [[ "$shipped" != "$claimed" ]]; then
      fail "$key: pin claims the shipped default is '$claimed' but $cite_file says '$shipped'"
    elif [[ "$value" == "$shipped" && -n "$shipped" ]]; then
      fail "$key: annotated as a pin but '$value' IS the shipped default — re-annotate as '(default)'"
    else
      pass "$key=$value pins over shipped default '${shipped:-<none>}' ($cite_file)"
    fi
  fi
done < "$ARACHNE_CONF"

# The walk itself must have walked: a parser that silently matches nothing
# would pass every line above by skipping it.
[[ "$N_DEFAULT" -ge 15 ]] && pass "parsed $N_DEFAULT '(default)' annotations (>= 15)" \
  || fail "parsed only $N_DEFAULT '(default)' annotations — the parser or the conf lost its annotations"
[[ "$N_PIN" -ge 25 ]] && pass "parsed $N_PIN '(pin; …)' annotations (>= 25)" \
  || fail "parsed only $N_PIN '(pin)' annotations — the parser or the conf lost its annotations"
[[ "$N_COMPUTED" -ge 1 ]] && pass "parsed $N_COMPUTED '(computed default)' annotations (>= 1)" \
  || fail "parsed no '(computed default)' annotations"

# The thirteen keys issue #4 found mislabeled '(default)' must each be a pin.
echo "--- arachne.conf: the thirteen issue-#4 filenames stay pinned ---"
ISSUE4_PINS=(
  POOL_CAP_FILE PUMP_STATE_NAME AGENT_LOG_NAME BRIEF_OUT_NAME GOAL_NOTE_NAME
  RESUME_NOTE_NAME RO_PROBE_FILE PUMP_LOG USAGE_RESET_FILE DISK_WATCHDOG_LOG
  HOOK_MARK_FILE MONITOR_NOTES_DIRNAME MONITOR_CACHE_BASE
)
for k in "${ISSUE4_PINS[@]}"; do
  if grep -E "^TASKPUMP_$k=" "$ARACHNE_CONF" | grep -q '# (pin; shipped default: '; then
    pass "TASKPUMP_$k is annotated as a pin"
  else
    fail "TASKPUMP_$k is not annotated '# (pin; shipped default: …)' (issue #4 regression)"
  fi
done

# ── The conf files load, and say what they claim (issues #5, #8) ──────────────
echo "--- arachne.conf: entrypoint / pre-flight coherence (issue #5) ---"

conf_get() {  # conf_get <conf> <var>  → value after sourcing, or "<UNSET>"
  env -i TMPDIR="${TMPDIR:-/tmp}" bash -c 'set -a; . "$1" || exit 9; printf "%s" "${!2-<UNSET>}"' _ "$1" "$2"
}

if v="$(conf_get "$ARACHNE_CONF" TASKPUMP_TASKS_DIR)"; then
  pass "arachne.conf sources cleanly (TASKPUMP_TASKS_DIR=$v)"
else
  fail "arachne.conf does not source cleanly"
fi

SHIPPED_ENTRYPOINT="$(extract_default TASKPUMP_ENTRYPOINT "$TP_ROOT/libexec/tp-pump")" \
  || fail "cannot derive the shipped TASKPUMP_ENTRYPOINT default from tp-pump"
pre_flight="$(conf_get "$ARACHNE_CONF" TASKPUMP_PRE_FLIGHT)"
entrypoint="$(conf_get "$ARACHNE_CONF" TASKPUMP_ENTRYPOINT)"
if [[ "$pre_flight" != "<UNSET>" && -n "$pre_flight" ]]; then
  pass "arachne.conf configures a pre-flight hook ($pre_flight)"
  # Only the shipped entrypoint runs the hook; a pin to any other path makes
  # the hook dead config that LOOKS configured — the issue #5 failure shape.
  if [[ "$entrypoint" == "<UNSET>" || "$entrypoint" == "$SHIPPED_ENTRYPOINT" ]]; then
    pass "the entrypoint honors it: ${entrypoint/<UNSET>/unset → $SHIPPED_ENTRYPOINT}"
  else
    fail "TASKPUMP_PRE_FLIGHT is set under TASKPUMP_ENTRYPOINT=$entrypoint, which is not the shipped $SHIPPED_ENTRYPOINT — the hook cannot run (issue #5)"
  fi
else
  fail "arachne.conf no longer configures TASKPUMP_PRE_FLIGHT (the reference consumer must exercise the hook seam)"
fi

# ── The dropped pin must stay dropped in prose too (issue #35) ────────────────
# Issue #5 deleted the /entrypoint-parallel.sh pin from arachne.conf. The
# comments that described that pin outlived it, so the tree kept telling
# readers the legacy layout "arrives via the conf pin" while the conf carried
# nothing — a reader who trusts that configures nothing and gets the shipped
# entrypoint. Deriving the check from the conf itself is what keeps the two in
# step: it enforces only while the conf really carries no TASKPUMP_ENTRYPOINT,
# and the coherence assertion above owns the case where the pin comes back.
echo "--- prose about the entrypoint pin tracks the conf (issue #35) ---"

# GNU grep's \b does not compose with .* here (it silently matches nothing), so
# the predicate spaces the verb explicitly instead. The alternation is the
# prepositions a live-pin claim is actually made with — "arrives via", "survives
# as", "comes from" — kept as a closed list because a bare "…pin…" on the same
# line as the path would condemn the past-tense sentences that must stay legal.
STALE_PIN_RE='entrypoint-parallel\.sh.* (as|via|from) .*pin'
# A guard that has never been shown to go red is not a guard, it is a comment:
# fire the predicate at the pre-#35 wording, and at a past-tense mention of the
# historical pin that must stay legal, before trusting its silence.
grep -qE "$STALE_PIN_RE" <<<'# layout (/entrypoint-parallel.sh) survives as the examples/arachne.conf pin.' \
  && pass "control: the stale-pin predicate fires on the pre-fix wording" \
  || fail "control: the stale-pin predicate MISSED the pre-fix wording — the guard is inert"
grep -qE "$STALE_PIN_RE" <<<'# the historical drives, which pinned /entrypoint-parallel.sh here.' \
  && fail "control: the predicate condemns a past-tense mention of the historical pin" \
  || pass "control: the predicate leaves a past-tense mention of the historical pin alone"
# The claim is what matters, not the preposition it is made with: an edit that
# says the same false thing another way must still trip the guard.
grep -qE "$STALE_PIN_RE" <<<"# The /entrypoint-parallel.sh layout comes from arachne.conf's pin." \
  && pass "control: the stale-pin predicate fires on a reworded live-pin claim" \
  || fail "control: the predicate MISSED a reworded live-pin claim — the guard only catches one phrasing"

if [[ "$entrypoint" == "<UNSET>" ]]; then
  for f in "$ARACHNE_CONF" "$TP_ROOT/taskpump.conf" "$PUMP" \
           "$TP_ROOT/tests/test-entrypoint.sh" "$TP_ROOT/docs/RUNNERS.md"; do
    rel="${f#"$TP_ROOT"/}"
    hits="$(grep -nE "$STALE_PIN_RE" "$f" 2>/dev/null)"
    if [[ -z "$hits" ]]; then
      pass "should claim no live arachne.conf entrypoint pin when the conf carries none: $rel"
    else
      fail "$rel still says the /entrypoint-parallel.sh layout arrives via a conf pin, but arachne.conf sets no TASKPUMP_ENTRYPOINT (issue #5):\n$hits"
    fi
  done
else
  pass "arachne.conf pins TASKPUMP_ENTRYPOINT again — the coherence check above owns that case"
fi

# The contiguous run of comment lines immediately above a given line: the block
# a reader reads as belonging to it.
comment_run_above() {  # comment_run_above <file> <1-indexed line>
  local f="$1" n="$2" i out=""
  local -a lines=()
  mapfile -t lines < "$f"
  for (( i = n - 2; i >= 0; i-- )); do
    [[ "${lines[i]}" == '#'* ]] || break
    out="${lines[i]}"$'\n'"$out"
  done
  printf '%s' "$out"
}

# The default's own comment is where a reader lands from the code, so it must
# carry the reason the pin is gone rather than a pointer to a pin that is not.
ep_line="$(grep -nF 'ENTRYPOINT="${TASKPUMP_ENTRYPOINT' "$PUMP" | head -1 | cut -d: -f1)"
if [[ -n "$ep_line" ]]; then
  if grep -qF 'issue #5' <<<"$(comment_run_above "$PUMP" "$ep_line")"; then
    pass "should cite issue #5 above the ENTRYPOINT default when the pin it used to name is gone"
  else
    fail "tp-pump's TASKPUMP_ENTRYPOINT comment does not cite issue #5 — a reader cannot tell why arachne.conf no longer pins it"
  fi
else
  fail "cannot find the TASKPUMP_ENTRYPOINT default in tp-pump"
fi

# ── The dogfood conf's commented fallback owns its hazard (issue #35) ─────────
# taskpump.conf configures TASKPUMP_PRE_FLIGHT and parks a commented
# TASKPUMP_ENTRYPOINT fallback beneath it. Uncommenting that line recreates the
# issue-#5 state exactly — a configured hook no entrypoint runs — so the block
# must say so where the operator would uncomment, not only in arachne.conf.
echo "--- taskpump.conf: the commented entrypoint fallback names its pre-flight hazard (issue #35) ---"

DOGFOOD_CONF="$TP_ROOT/taskpump.conf"
dog_ep_line="$(grep -nE '^#[[:space:]]*TASKPUMP_ENTRYPOINT=' "$DOGFOOD_CONF" | head -1 | cut -d: -f1)"
dog_ep_value="$(grep -E '^#[[:space:]]*TASKPUMP_ENTRYPOINT=' "$DOGFOOD_CONF" | head -1 | sed 's/^#[[:space:]]*TASKPUMP_ENTRYPOINT=//')"
if ! grep -qE '^TASKPUMP_PRE_FLIGHT=' "$DOGFOOD_CONF"; then
  pass "taskpump.conf configures no pre-flight hook — nothing for the fallback to make inert"
elif [[ -z "$dog_ep_line" || "$dog_ep_value" == "$SHIPPED_ENTRYPOINT" ]]; then
  pass "taskpump.conf parks no non-shipped entrypoint fallback"
else
  block="$(comment_run_above "$DOGFOOD_CONF" "$dog_ep_line")"
  if grep -qF 'TASKPUMP_PRE_FLIGHT' <<<"$block" && grep -qF 'inert' <<<"$block"; then
    pass "should warn that uncommenting the entrypoint fallback leaves TASKPUMP_PRE_FLIGHT inert when the dogfood conf configures the hook"
  else
    fail "taskpump.conf's commented TASKPUMP_ENTRYPOINT=$dog_ep_value carries no warning that it makes the TASKPUMP_PRE_FLIGHT above it inert (issue #5's hazard, one uncomment away):\n$block"
  fi
fi

echo "--- arachne.conf: the unflagged pool cap is the shipped default (issue #8) ---"

JOBS_DEFAULT="$(extract_default TASKPUMP_JOBS "$TP_ROOT/libexec/tp-pump")" \
  || fail "cannot derive the shipped TASKPUMP_JOBS default from tp-pump"
conf_jobs="$(conf_get "$ARACHNE_CONF" TASKPUMP_JOBS)"
if [[ "$conf_jobs" == "$JOBS_DEFAULT" ]]; then
  pass "arachne.conf sets TASKPUMP_JOBS=$conf_jobs, the shipped default"
else
  fail "arachne.conf sets TASKPUMP_JOBS=$conf_jobs but the shipped default is $JOBS_DEFAULT — adopting the conf silently changes the unflagged cap (issue #8)"
fi

# Behavioral: a real dry-run plan under the conf. The cap in the plan header
# must be the shipped default, and --jobs must still widen it per invocation —
# the invocation shape the historical drains actually used.
FIX="$TMP/fixture"; FTASKS="$FIX/ops/task-loop/tasks"
mkdir -p "$FTASKS"
cat >| "$FTASKS/F80.0.md" <<'EOF'
---
id: F80.0
phase: F80
title: fixture F80.0
status: open
claimed_by: null
claimed_at: null
turn_budget_remaining: null
consecutive_failed_iterations: 0
blockers: []
completed_by_commits: []
files: []
goal: drain F80.0
---
# F80.0
EOF
git init -q -b main "$FIX"
git -C "$FIX" config user.name 'taskpump-fixture'
git -C "$FIX" config user.email 'fixture@taskpump.test'
git -C "$FIX" add -A
git -C "$FIX" commit -qm seed

BIN="$TMP/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "ps" ]]; then exit 0; fi\nexit 0\n' >| "$BIN/docker"
chmod +x "$BIN/docker"

plan() {  # plan <extra pump args...>
  ( cd "$FIX" && \
    TASKPUMP_CONFIG="$ARACHNE_CONF" \
    TASKPUMP_TASKS_DIR="$FTASKS" \
    TASKPUMP_PUMP_TASKS_DIR="$FTASKS" \
    TASKPUMP_PUMP_OPS_DIR="$FIX/ops" \
    TASKPUMP_TASK_NOCOMMIT=1 \
    TASKPUMP_TOKEN_GATE=0 \
    TASKPUMP_PUMP_NO_GH=1 \
    TASKPUMP_PUMP_WORKTREES_DIR="$FIX/.worktrees" \
    DOCKER="$BIN/docker" \
    "$PUMP" --dry-run --no-health-gate --no-usage-gate --no-disk-gate "$@" ) 2>&1
}

out="$(plan --phases F80)"; rc=$?
[[ $rc -eq 0 ]] && pass "dry-run plan under arachne.conf exits 0" \
  || fail "dry-run plan under arachne.conf rc=$rc:\n$out"
if grep -q '^arachne-pump plan' <<<"$out"; then
  pass "the conf actually loaded (plan header names arachne-pump)"
else
  fail "plan header does not name arachne-pump — the conf silently did not load:\n$out"
fi
if grep -q "cap $JOBS_DEFAULT," <<<"$out"; then
  pass "unflagged plan runs at the shipped cap of $JOBS_DEFAULT"
else
  fail "unflagged plan cap is not the shipped default $JOBS_DEFAULT:\n$(grep 'plan —' <<<"$out")"
fi
grep -qE 'LAUNCH +F80' <<<"$out" && pass "the plan is not empty (F80 would launch)" \
  || fail "no LAUNCH F80 in the dry-run plan:\n$out"

out="$(plan --phases F80 --jobs 6)"
if grep -q 'cap 6,' <<<"$out"; then
  pass "--jobs 6 still widens the cap per invocation (the documented drain shape)"
else
  fail "--jobs 6 did not widen the cap:\n$(grep 'plan —' <<<"$out")"
fi

# ── preflight-example.sh honors TASKPUMP_CONTAINER_HOME (issue #9) ────────────
echo "--- preflight-example.sh: settings land in TASKPUMP_CONTAINER_HOME ---"

bash -n "$PREFLIGHT" && pass "preflight-example.sh parses (bash -n)" \
  || fail "preflight-example.sh has a syntax error"

STUBS="$TMP/stubs"; mkdir -p "$STUBS"
printf '#!/usr/bin/env bash\nexit 0\n' >| "$STUBS/iptables"
chmod +x "$STUBS/iptables"

CONSUMER="$TMP/consumer-repo"; mkdir -p "$CONSUMER" "$TMP/ws"
cat >| "$CONSUMER/claude-mcp.json" <<'EOF'
{
  "mcpServers": { "context7": { "command": "npx" } },
  "permissions": { "defaultMode": "default", "allow": ["Bash(ls:*)"] }
}
EOF
cat >| "$CONSUMER/claude-settings-auto.json" <<'EOF'
{ "permissions": { "defaultMode": "auto", "allow": ["Bash(cargo test:*)"] } }
EOF

run_preflight() {  # run_preflight <container-home> <repo-root>
  env PATH="$STUBS:$PATH" \
    WORKSPACE_PATH="$TMP/ws" \
    REPO_ROOT="$2" \
    LOG_FILE="$TMP/preflight.log" \
    TASKPUMP_CONTAINER_USER="$(id -un)" \
    TASKPUMP_CONTAINER_HOME="$1" \
    bash "$PREFLIGHT" 2>&1
}

if command -v jq >/dev/null 2>&1; then
  AGENT_HOME="$TMP/agent-home"   # deliberately no pre-created .claude/
  out="$(run_preflight "$AGENT_HOME" "$CONSUMER")"; rc=$?
  [[ $rc -eq 0 ]] && pass "hook exits 0 with a fixture home (smoke failure is non-fatal)" \
    || fail "hook rc=$rc:\n$out"
  grep -q 'Pre-flight complete' <<<"$out" && pass "hook runs to completion" \
    || fail "no 'Pre-flight complete' in hook output:\n$out"

  SETTINGS="$AGENT_HOME/.claude/settings.json"
  if [[ -f "$SETTINGS" ]]; then
    pass "merged settings landed in \$TASKPUMP_CONTAINER_HOME/.claude/ (dir auto-created)"
    mode="$(jq -r '.permissions.defaultMode // empty' "$SETTINGS")"
    [[ "$mode" == "auto" ]] && pass "Auto Mode settings win the merge (defaultMode=auto)" \
      || fail "merged defaultMode is '$mode' (expected auto)"
    got="$(jq -r '.mcpServers.context7.command // empty' "$SETTINGS")"
    [[ "$got" == "npx" ]] && pass "MCP servers survive the merge" \
      || fail "merge lost mcpServers (context7.command='$got')"
  else
    fail "no settings.json at $SETTINGS — the hook wrote the session config into a home the session never reads (issue #9)"
  fi

  # Single-sided fallback: only the Auto file present.
  AGENT_HOME2="$TMP/agent-home2"
  CONSUMER2="$TMP/consumer-repo2"; mkdir -p "$CONSUMER2"
  cp "$CONSUMER/claude-settings-auto.json" "$CONSUMER2/"
  out="$(run_preflight "$AGENT_HOME2" "$CONSUMER2")"
  mode="$(jq -r '.permissions.defaultMode // empty' "$AGENT_HOME2/.claude/settings.json" 2>/dev/null)"
  [[ "$mode" == "auto" ]] && pass "Auto-only fallback still lands in the fixture home" \
    || fail "Auto-only run left no usable settings in $AGENT_HOME2:\n$out"
else
  echo "  (jq unavailable — skipping the preflight behavioral cases)"
fi

# ── The other two example confs, held to the same standard ────────────────────
echo "--- minimal.conf and taskpump.conf.example ---"

if v="$(conf_get "$MINIMAL_CONF" TASKPUMP_TASKS_DIR)"; then
  probe_default="$(extract_default TASKPUMP_LEDGER_PROBE "$TP_ROOT/libexec/tp-task")"
  [[ "$v" == "$probe_default" ]] \
    && pass "minimal.conf's TASKPUMP_TASKS_DIR=$v restates the shipped ledger probe default" \
    || fail "minimal.conf sets TASKPUMP_TASKS_DIR=$v but the shipped probe default is '$probe_default' — its 'only restates the defaults' claim is false"
else
  fail "minimal.conf does not source cleanly"
fi
idp="$(conf_get "$MINIMAL_CONF" TASKPUMP_ID_PATTERN)"
idp_default="$(extract_default TASKPUMP_ID_PATTERN "$TP_ROOT/libexec/tp-task")"
[[ "$idp" == "$idp_default" ]] \
  && pass "minimal.conf's TASKPUMP_ID_PATTERN restates the shipped default" \
  || fail "minimal.conf's TASKPUMP_ID_PATTERN is '$idp'; the shipped default is '$idp_default'"

leaked="$(env -i TMPDIR="${TMPDIR:-/tmp}" bash -c 'set -a; . "$1" || exit 9; compgen -v | grep "^TASKPUMP_" || true' _ "$CENSUS_CONF")"
if [[ -z "$leaked" ]]; then
  pass "taskpump.conf.example sets nothing when sourced (every key stays commented)"
else
  fail "taskpump.conf.example actually sets: $leaked — the census must stay fully commented"
fi

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]] || exit 1
