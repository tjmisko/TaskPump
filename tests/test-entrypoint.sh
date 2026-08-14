#!/usr/bin/env bash
# test-entrypoint.sh — guard for the claude-docker runner: entrypoint.sh,
# preflight-example.sh, and runner.sh.
#
# Two kinds of assertion live here.
#
# Static inspection, for the things that must never regress but cannot be
# executed on a dev host: the session runs under `--permission-mode auto`;
# `--dangerously-skip-permissions` never appears; the container credential copy
# strips the OAuth refresh token; the pre-flight applies the agent's settings.
#
# Behavioural, via two test seams the entrypoint exposes.
# TASKPUMP_ENTRYPOINT_TEST_MODE=plan resolves the environment, assembles the
# prompt, prints a REPORT block and exits — no credentials, no firewall, no
# session. =preflight additionally installs credentials and runs the pre-flight
# hook. That lets the harness exercise the real resolution and ordering logic
# rather than grepping for it.
#
# runner.sh is driven with DOCKER=/bin/echo (or a recording stub), so no real
# container is ever created.
#
# Run: ./tests/test-entrypoint.sh   (offline; no container launched)
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
EP="$TP_ROOT/runners/claude-docker/entrypoint.sh"
PF="$TP_ROOT/runners/claude-docker/preflight-example.sh"
RUNNER="$TP_ROOT/runners/claude-docker/runner.sh"

# Hermeticity: ignore any taskpump.conf in the repo this suite happens to run
# from — the tools discover config by walking up from $PWD, and a leaked conf
# reconfigures every fixture invocation below. run-all.sh exports the same
# switch; this one covers standalone runs.
export TASKPUMP_NO_CONF=1

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# The workspace-CLI default is a bare `tp` resolved on PATH (G1.6), and the
# entrypoint refuses to start when it cannot be found. Most fixtures here are
# not about that default, so a stub tp stays on PATH for the whole suite —
# hermetic against whether the host has a real tp installed — and the bare-image
# error path is exercised in its own cases below, under a PATH without it.
TPBIN="$WORK/tp-on-path"; mkdir -p "$TPBIN"
printf '#!/usr/bin/env bash\nexit 0\n' >| "$TPBIN/tp"
chmod +x "$TPBIN/tp"
export PATH="$TPBIN:$PATH"

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

[[ -f "$EP" ]]     || { echo "FAIL: entrypoint not found at $EP" >&2; exit 1; }
[[ -f "$PF" ]]     || { echo "FAIL: preflight example not found at $PF" >&2; exit 1; }
[[ -f "$RUNNER" ]] || { echo "FAIL: runner not found at $RUNNER" >&2; exit 1; }

# Every name on either side of the environment contract. Cleared before each
# behavioural run so the harness's own environment cannot leak into a case.
CONTRACT_VARS="
TASKPUMP_WORKSPACE_PATH TP_WORKSPACE WORKSPACE_PATH
TASKPUMP_REPO_ROOT TP_REPO_ROOT REPO_ROOT
TASKPUMP_LEDGER_REPO TP_LEDGER_REPO ARACHNE_PUMP_OPS_DIR
TASKPUMP_TASKS_DIR ARACHNE_TASKS_DIR
TASKPUMP_TASK_OUT ARACHNE_TASK_OUT TASKPUMP_TASK_FILE_EXT
TASKPUMP_BRIEF TP_BRIEF ARACHNE_BRIEF
TASKPUMP_RESUME_NOTE TP_RESUME_NOTE ARACHNE_RESUME_NOTE
TASKPUMP_TASK_ID TP_TASK_ID ARACHNE_TASK_ID
TASKPUMP_PHASE TP_PHASE ARACHNE_PHASE
TASKPUMP_MAX_TURNS TP_MAX_TURNS MAX_TURNS
TASKPUMP_AGENT_MODEL TP_MODEL AGENT_MODEL
TASKPUMP_SAFETY_TURNS TP_SAFETY_TURNS
TASKPUMP_WORKSPACE_TASK_CLI TP_WORKSPACE_TASK_CLI
TASKPUMP_INSTALL_MOUNT TP_INSTALL_MOUNT
TASKPUMP_CONTAINER_USER TP_CONTAINER_USER
TASKPUMP_CONTAINER_HOME TP_CONTAINER_HOME
TASKPUMP_PRE_FLIGHT TP_PRE_FLIGHT
TASKPUMP_TASKS_DIR TP_TASKS_DIR TASKPUMP_TASK_OUT TP_TASK_OUT
TASKPUMP_TASK_FILE_EXT TP_TASK_FILE_EXT
TASKPUMP_AGENT_LOG_NAME TP_AGENT_LOG_NAME
TASKPUMP_GOAL_NOTE_NAME TP_GOAL_NOTE_NAME
TASKPUMP_RESUME_NOTE_NAME TP_RESUME_NOTE_NAME
TASKPUMP_RO_PROBE_FILE TP_RO_PROBE_FILE
TASKPUMP_HOST_CRED_MOUNT TP_HOST_CRED_MOUNT
TASKPUMP_HOST_CONFIG_MOUNT TP_HOST_CONFIG_MOUNT
TASKPUMP_CRED_REFRESH_INTERVAL_S TP_CRED_REFRESH_INTERVAL_S CRED_REFRESH_INTERVAL_S
TASKPUMP_AGENT_WALL_TIMEOUT_S TP_AGENT_WALL_TIMEOUT_S AGENT_WALL_TIMEOUT_S
TASKPUMP_ENTRYPOINT_TEST_MODE GITHUB_TOKEN
TP_CONTAINER_NAME ARACHNE_CONTAINER_NAME
TP_IMAGE ARACHNE_IMAGE TP_ENTRYPOINT ARACHNE_ENTRYPOINT
TP_BRANCH ARACHNE_BRANCH
TP_CLAUDE_DIR CLAUDE_DIR TP_CLAUDE_JSON CLAUDE_JSON
TP_MEMORY_MAX AGENT_MEMORY_MAX TP_MEMORY_SWAP AGENT_MEMORY_SWAP
TP_CONTAINER_RUN_USER TP_ENV_PASSTHROUGH
"

# run_ep <var=value>... — run the entrypoint in a cleared environment with only
# the named variables set. Prints its combined output.
run_ep() {
  (
    # shellcheck disable=SC2086  # deliberate word splitting over the name list
    unset $CONTRACT_VARS
    local kv
    for kv in "$@"; do export "$kv"; done
    bash "$EP" 2>&1
  )
}

# run_runner <verb> <var=value>... — same, for runner.sh.
run_runner() {
  local verb="$1"; shift
  (
    # shellcheck disable=SC2086
    unset $CONTRACT_VARS
    local kv
    for kv in "$@"; do export "$kv"; done
    bash "$RUNNER" "$verb" 2>&1
  )
}

report() { grep '^REPORT ' <<<"$1" | sed 's/^REPORT //'; }

# ── Permission posture ─────────────────────────────────────────────────────────
echo "--- permission posture ---"
if grep -qE -- '--permission-mode[[:space:]]+auto' "$EP"; then
  pass "launches claude with --permission-mode auto"
else
  fail "entrypoint.sh does not pass --permission-mode auto"
fi

# Strip full-line comments first: the header legitimately *names* the flag to say
# it is NOT used. The invariant is that no EXECUTABLE line passes it to claude.
if grep -vE '^[[:space:]]*#' "$EP" | grep -q -- '--dangerously-skip-permissions'; then
  fail "an executable line of entrypoint.sh passes --dangerously-skip-permissions (must NOT)"
else
  pass "no --dangerously-skip-permissions on any executable line"
fi

# ── Pre-seeded allow rules are read + applied (now the pre-flight's job) ───────
echo "--- pre-seeded Auto Mode allow rules (pre-flight) ---"
if grep -q 'claude-settings-auto.json' "$PF"; then
  pass "pre-flight references claude-settings-auto.json (the pre-seeded allow list)"
else
  fail "preflight-example.sh never references claude-settings-auto.json"
fi
if grep -q 'settings.json' "$PF"; then
  pass "pre-flight writes a merged settings.json for the session"
else
  fail "preflight-example.sh never writes settings.json"
fi

# ── The merge itself, against a fixture allow file ─────────────────────────────
# The real claude-settings-auto.json is a consumer-side artifact and does not
# ship with TaskPump, so there is nothing in the tree to inspect. What is
# TaskPump's to guarantee is the *merge semantics* the reference pre-flight
# applies, so that is what gets exercised: a fixture MCP config and a fixture
# Auto Mode config, combined by the pre-flight's own jq expression, must yield a
# settings.json that keeps the MCP servers and lets the Auto settings win every
# conflicting key.
echo "--- Auto Mode settings merge ---"
MERGE_EXPR='.[0] * .[1]'
if grep -qF -- "jq -s '$MERGE_EXPR'" "$PF"; then
  pass "pre-flight merges MCP + Auto settings with jq -s '$MERGE_EXPR'"
else
  fail "preflight-example.sh no longer merges with jq -s '$MERGE_EXPR' (update this test with it)"
fi

FIX_MCP="$WORK/claude-mcp.json"
FIX_AUTO="$WORK/claude-settings-auto.json"
cat >| "$FIX_MCP" <<'EOF'
{
  "mcpServers": { "context7": { "command": "npx", "args": ["-y", "@upstash/context7-mcp"] } },
  "permissions": { "defaultMode": "default", "allow": ["Bash(ls:*)"] }
}
EOF
cat >| "$FIX_AUTO" <<'EOF'
{
  "permissions": {
    "defaultMode": "auto",
    "allow": ["Bash(cargo test:*)", "Bash(git commit:*)"]
  }
}
EOF

if command -v jq >/dev/null 2>&1; then
  mode=$(jq -r '.permissions.defaultMode // empty' "$FIX_AUTO" 2>/dev/null)
  [[ "$mode" == "auto" ]] && pass "fixture allow file declares permissions.defaultMode == auto" \
    || fail "fixture permissions.defaultMode is '$mode' (expected auto)"
  n=$(jq -r '.permissions.allow | length' "$FIX_AUTO" 2>/dev/null)
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] && pass "fixture permissions.allow has $n pre-approved rules" \
    || fail "fixture permissions.allow is empty or missing"

  MERGED="$WORK/settings.json"
  jq -s "$MERGE_EXPR" "$FIX_MCP" "$FIX_AUTO" >| "$MERGED" 2>/dev/null

  got=$(jq -r '.mcpServers.context7.command // empty' "$MERGED" 2>/dev/null)
  [[ "$got" == "npx" ]] && pass "merge keeps the MCP servers from claude-mcp.json" \
    || fail "merge lost mcpServers (context7.command = '$got')"

  got=$(jq -r '.permissions.defaultMode // empty' "$MERGED" 2>/dev/null)
  [[ "$got" == "auto" ]] && pass "merge lets Auto Mode win defaultMode over the MCP config" \
    || fail "merged defaultMode is '$got' (expected auto to win)"

  got=$(jq -r '.permissions.allow | index("Bash(cargo test:*)") // empty' "$MERGED" 2>/dev/null)
  [[ -n "$got" ]] && pass "merge carries the Auto Mode allow rules into settings.json" \
    || fail "merged permissions.allow lost the Auto Mode rules"

  got=$(jq -r '.permissions.allow | index("Bash(ls:*)") // empty' "$MERGED" 2>/dev/null)
  [[ -z "$got" ]] && pass "Auto Mode's allow list replaces the MCP config's, not appends" \
    || fail "merged permissions.allow still carries the MCP config's rules"
else
  echo "  (jq unavailable — skipping the merge assertions)"
fi

# Both single-sided fallbacks must exist, or a run with only one of the two files
# silently launches with no settings.json at all.
if grep -qF 'cp "$AUTO_JSON" "$AGENT_SETTINGS"' "$PF" \
   && grep -qF 'cp "$MCP_JSON" "$AGENT_SETTINGS"' "$PF"; then
  pass "pre-flight falls back to whichever config exists when only one is present"
else
  fail "preflight-example.sh is missing a single-sided fallback for MCP-only / Auto-only"
fi

# The settings must land in the session user's home as the entrypoint exports it
# (TASKPUMP_CONTAINER_HOME / TASKPUMP_CONTAINER_USER), never a hardcoded
# /home/dev — a non-default image would lose its MCP config and allow rules
# silently (issue #9). Behavioral coverage: tests/test-example-confs.sh runs the
# hook against a fixture home.
if grep -vE '^[[:space:]]*#' "$PF" | grep -q '/home/dev'; then
  fail "an executable line of preflight-example.sh hardcodes /home/dev (must use TASKPUMP_CONTAINER_HOME)"
else
  pass "no executable line hardcodes /home/dev"
fi
if grep -q 'TASKPUMP_CONTAINER_HOME' "$PF" && grep -q 'TASKPUMP_CONTAINER_USER' "$PF"; then
  pass "pre-flight resolves the settings path through TASKPUMP_CONTAINER_HOME/_USER"
else
  fail "preflight-example.sh never reads TASKPUMP_CONTAINER_HOME/_USER"
fi

# ── Smoke test is run before the session ───────────────────────────────────────
echo "--- pre-session smoke test ---"
if grep -q 'smoke_test.sh' "$PF"; then
  pass "pre-flight runs smoke_test.sh before the session"
else
  fail "preflight-example.sh does not run smoke_test.sh"
fi

# ── Access-token-only credentials (no refresh-token rotation by containers) ─────
# The container must strip .claudeAiOauth.refreshToken from its credential copy so
# it can never rotate the host's shared OAuth token and log the host out.
echo "--- access-token-only credentials ---"
if grep -q "del(.claudeAiOauth.refreshToken)" "$EP"; then
  pass "strips refreshToken from the container credential copy (access-token-only)"
else
  fail "entrypoint.sh never strips .claudeAiOauth.refreshToken"
fi
# The strip must happen at STARTUP, not only in the periodic refresher — otherwise
# a refresh in the first CRED_REFRESH_INTERVAL_S window rotates the host token.
if grep -c "install_access_only_credentials" "$EP" | awk '{exit !($1>=2)}'; then
  pass "install_access_only_credentials used at startup AND in the refresher"
else
  fail "install_access_only_credentials must be called at startup and in the refresher"
fi
# The full host credentials.json must never be plain-copied into the agent home as
# the live token (that would carry the refresh token). The only cp of a
# .credentials.json path would be a regression.
if grep -vE '^[[:space:]]*#' "$EP" | grep -E 'cp[[:space:]].*\.credentials\.json'; then
  fail "an executable line plain-copies .credentials.json (carries the refresh token)"
else
  pass "no plain cp of .credentials.json (only the stripped install path)"
fi

# ── The split itself ───────────────────────────────────────────────────────────
echo "--- generic / project split ---"
# The generic half must not carry the project's egress profile or smoke test as
# its normal path. The transitional legacy fallback is allowed to, and is the
# only thing that may name them.
legacy_start=$(grep -n '^legacy_pre_flight()' "$EP" | cut -d: -f1)
legacy_end=$(awk -v a="${legacy_start:-0}" 'NR>a && /^}/ {print NR; exit}' "$EP")
if [[ -z "$legacy_start" ]]; then
  fail "entrypoint has no legacy_pre_flight (the transitional fallback is gone)"
else
  stray=$(grep -n 'iptables' "$EP" | awk -F: -v a="$legacy_start" -v b="$legacy_end" '$1<a || $1>b')
  if [[ -n "$stray" ]]; then
    fail "iptables rules outside the transitional legacy_pre_flight: $stray"
  else
    pass "iptables rules appear only inside the transitional legacy_pre_flight"
  fi
fi
if grep -q 'TASKPUMP_PRE_FLIGHT' "$EP"; then
  pass "entrypoint reads the TASKPUMP_PRE_FLIGHT hook"
else
  fail "entrypoint has no TASKPUMP_PRE_FLIGHT hook seam"
fi
# preflight-example.sh is a reference, not wiring. Documentation may name it; no
# executable line anywhere may run it, or "example" would quietly become "default".
wired=$(grep -rn 'preflight-example' "$TP_ROOT/libexec" "$TP_ROOT/lib" "$TP_ROOT/bin" \
          "$TP_ROOT/runners/claude-docker/entrypoint.sh" 2>/dev/null \
        | grep -vE ':[[:space:]]*#')
if [[ -n "$wired" ]]; then
  fail "an executable line references preflight-example.sh (it must stay unwired): $wired"
else
  pass "preflight-example.sh is unwired: only comments name it"
fi
if grep -qE 'EXAMPLE, NOT WIRED' "$PF"; then
  pass "preflight-example.sh is marked as an example"
else
  fail "preflight-example.sh is not marked as an example"
fi
# The task CLI must be reached through the configurable path, not a literal.
if grep -vE '^[[:space:]]*#' "$EP" | grep -q "WORKSPACE_PATH/scripts/arachne-task"; then
  fail "entrypoint still hardcodes \$WORKSPACE_PATH/scripts/arachne-task"
else
  pass "task CLI is reached through TASKPUMP_WORKSPACE_TASK_CLI, not a literal path"
fi
n=$(grep -cE "^\s+\\\$TASK_CLI_ARGV " "$EP")
[[ "$n" -eq 3 ]] && pass "all three task-CLI call sites go through \$TASK_CLI_ARGV (claim, --start, --end)" \
  || fail "expected 3 \$TASK_CLI_ARGV call sites, found $n"
# And none may still use the raw single-word form: '$TASK_CLI' claim would
# invoke `tp claim` — an unknown verb swallowed by || true, the silent no-op
# G1.6's completion notes flagged for exactly this task.
if grep -qE "^\s+'\\\$TASK_CLI'" "$EP"; then
  fail "a session call site still uses the single-word '\$TASK_CLI' form (breaks the bare tp default)"
else
  pass "no session call site bypasses \$TASK_CLI_ARGV"
fi

# ── Exit-code discipline: 75 must be reachable only before heartbeat --start ────
echo "--- exit-code discipline ---"
hb_line=$(grep -n "heartbeat '\$TASK_ID' --start" "$EP" | head -1 | cut -d: -f1)
last75=$(grep -n 'exit 75' "$EP" | grep -v ':[[:space:]]*#' | tail -1 | cut -d: -f1)
if [[ -n "$hb_line" && -n "$last75" && "$last75" -lt "$hb_line" ]]; then
  pass "every exit 75 (EX_TEMPFAIL) precedes the heartbeat --start (line $last75 < $hb_line)"
else
  fail "exit 75 at line ${last75:-none} is not before heartbeat --start at line ${hb_line:-none}"
fi

# ── Behavioural fixtures ───────────────────────────────────────────────────────
mk_ws() {  # mk_ws <name> -> prints the fixture root
  local root="$WORK/$1"
  mkdir -p "$root/wt" "$root/tasks" "$root/home"
  printf 'kickoff brief body\n' >| "$root/brief.md"
  cat >| "$root/tasks/F9.1.md" <<'EOF'
---
id: F9.1
phase: F9
status: open
goal: drain F9 without stranding work
---
# F9.1
EOF
  printf '%s\n' "$root"
}

echo "--- canonical vs legacy environment equivalence ---"
# The goal-note NAME is pinned on both sides (its .arachne-goal.md default
# flips to .taskpump-goal.md in G1.3, and the name is incidental to what these
# cases assert). GOAL_NOTE_NAME has no legacy spelling, so pinning it on the
# legacy side too keeps the comparison exact without diluting it.
R1=$(mk_ws canon)
out_canon=$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TP_WORKSPACE="$R1/wt" TP_REPO_ROOT="$R1" TP_BRIEF="$R1/brief.md" \
  TP_TASK_ID=F9.1 TP_PHASE=F9 TP_MODEL=haiku TP_MAX_TURNS=42 \
  TASKPUMP_TASKS_DIR="$R1/tasks" TASKPUMP_GOAL_NOTE_NAME=.arachne-goal.md)
rc_canon=$?
out_legacy=$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  WORKSPACE_PATH="$R1/wt" REPO_ROOT="$R1" ARACHNE_BRIEF="$R1/brief.md" \
  ARACHNE_TASK_ID=F9.1 ARACHNE_PHASE=F9 AGENT_MODEL=haiku MAX_TURNS=42 \
  ARACHNE_TASKS_DIR="$R1/tasks" TASKPUMP_GOAL_NOTE_NAME=.arachne-goal.md)
rc_legacy=$?
[[ $rc_canon -eq 0 && $rc_legacy -eq 0 ]] \
  && pass "plan mode exits 0 under both spellings" \
  || fail "plan mode rc: canonical=$rc_canon legacy=$rc_legacy\n$out_canon\n$out_legacy"
rep_canon=$(report "$out_canon"); rep_legacy=$(report "$out_legacy")
if [[ -n "$rep_canon" && "$rep_canon" == "$rep_legacy" ]]; then
  pass "TP_*-only and ARACHNE_*-only environments resolve identically"
else
  fail "canonical/legacy resolution differs:\n--- canonical ---\n$rep_canon\n--- legacy ---\n$rep_legacy"
fi
grep -q "prompt_parts=$R1/wt/.arachne-goal.md $R1/brief.md" <<<"$rep_canon" \
  && pass "stdin assembly is goal then brief when there is no resume note" \
  || fail "unexpected prompt assembly:\n$rep_canon"
grep -q '^model=haiku$' <<<"$rep_canon" && pass "model resolves from TP_MODEL / AGENT_MODEL" \
  || fail "model not resolved:\n$rep_canon"
grep -q '^max_turns=42$' <<<"$rep_canon" && pass "max_turns resolves from TP_MAX_TURNS / MAX_TURNS" \
  || fail "max_turns not resolved:\n$rep_canon"

# Both spellings present: the canonical name wins, matching lib/config.sh, where
# TASKPUMP_X outranks ARACHNE_X when both are in the environment.
out_both=$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TP_WORKSPACE="$R1/wt" WORKSPACE_PATH=/nonexistent-legacy \
  TP_REPO_ROOT="$R1" REPO_ROOT=/nonexistent-legacy \
  TP_BRIEF="$R1/brief.md" ARACHNE_BRIEF=/nonexistent-legacy/brief.md \
  TP_MODEL=opus AGENT_MODEL=sonnet \
  TASKPUMP_TASKS_DIR="$R1/tasks")
rep_both=$(report "$out_both")
grep -q "^workspace=$R1/wt$" <<<"$rep_both" && grep -q '^model=opus$' <<<"$rep_both" \
  && pass "canonical name wins when both spellings are in the environment" \
  || fail "legacy name won over canonical:\n$rep_both"

# Defaults are baked, not required.
R2=$(mk_ws defaults)
rep_def=$(report "$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TP_WORKSPACE="$R2/wt" TP_REPO_ROOT="$R2" TP_BRIEF="$R2/brief.md")")
grep -q '^model=opus$'  <<<"$rep_def" && pass "model defaults to opus"      || fail "model default wrong:\n$rep_def"
grep -q '^max_turns=600$' <<<"$rep_def" && pass "max_turns defaults to 600" || fail "max_turns default wrong:\n$rep_def"
grep -q '^safety_turns=3$' <<<"$rep_def" && pass "safety_turns defaults to 3" || fail "safety_turns default wrong:\n$rep_def"
grep -q "^ledger_repo=$R2/ops$" <<<"$rep_def" && pass "ledger repo defaults to <repo>/ops" || fail "ledger default wrong:\n$rep_def"
grep -q "^tasks_dir=$R2/ops/tasks$" <<<"$rep_def" \
  && pass "tasks dir defaults to <ledger>/tasks (G1.6 ledger shape)" \
  || fail "tasks dir default wrong:\n$rep_def"
# The bare default is `tp`, found on PATH (the suite keeps a stub there); the
# no-tp-on-PATH error path has its own section below. The arachne.conf-pinned
# spelling stays covered by the override cases just after this.
grep -q '^task_cli=tp$' <<<"$rep_def" \
  && pass "workspace task CLI defaults to tp on PATH (G1.6)" \
  || fail "task CLI default wrong:\n$rep_def"
# tp keeps its ledger verbs under `tp task`; the bare default must expand to
# that invocation or every safety-net call would be `tp claim` — an unknown
# verb swallowed by || true (the silent no-op G1.6's completion notes flagged).
grep -q '^task_cli_argv=tp task$' <<<"$rep_def" \
  && pass "the bare tp default is invoked as 'tp task' (G4.3 verb grammar)" \
  || fail "bare-default invocation wrong:\n$rep_def"

# The workspace task CLI is the consumer's shim and must be overridable, both by
# a workspace-relative and an absolute path.
rep_cli=$(report "$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TP_WORKSPACE="$R2/wt" TP_REPO_ROOT="$R2" TP_BRIEF="$R2/brief.md" \
  TASKPUMP_WORKSPACE_TASK_CLI=bin/tp-task)")
grep -q "^task_cli=$R2/wt/bin/tp-task$" <<<"$rep_cli" \
  && pass "a relative TASKPUMP_WORKSPACE_TASK_CLI resolves under the workspace" \
  || fail "relative task-CLI override wrong:\n$rep_cli"
rep_cli=$(report "$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TP_WORKSPACE="$R2/wt" TP_REPO_ROOT="$R2" TP_BRIEF="$R2/brief.md" \
  TASKPUMP_WORKSPACE_TASK_CLI=/usr/local/bin/tp)")
grep -q '^task_cli=/usr/local/bin/tp$' <<<"$rep_cli" \
  && pass "an absolute TASKPUMP_WORKSPACE_TASK_CLI is used as given" \
  || fail "absolute task-CLI override wrong:\n$rep_cli"
# The grammar keys on the resolved CLI's BASENAME, not the literal 'tp': a tp
# pinned by absolute path is still tp and still keeps its verbs under `task`.
# Keying on the literal would take the direct-verb branch and every safety-net
# call would be `/usr/local/bin/tp claim` — the G1.6 silent no-op, reborn one
# rung up the resolution order.
grep -q '^task_cli_argv=/usr/local/bin/tp task$' <<<"$rep_cli" \
  && pass "a tp pinned by path keeps the 'tp task' verb grammar (basename keying)" \
  || fail "pinned-by-path tp invocation wrong:\n$rep_cli"
# The arachne.conf-pinned spelling, literally: a consumer that vendors its shim
# keeps exactly the pre-flip behaviour.
rep_cli=$(report "$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TP_WORKSPACE="$R2/wt" TP_REPO_ROOT="$R2" TP_BRIEF="$R2/brief.md" \
  TASKPUMP_WORKSPACE_TASK_CLI=scripts/arachne-task)")
grep -q "^task_cli=$R2/wt/scripts/arachne-task$" <<<"$rep_cli" \
  && pass "the arachne.conf-pinned scripts/arachne-task resolves under the workspace as before" \
  || fail "pinned task-CLI spelling wrong:\n$rep_cli"
# A pinned shim keeps the direct-verb grammar: no `task` verb is inserted.
grep -q "^task_cli_argv=$R2/wt/scripts/arachne-task$" <<<"$rep_cli" \
  && pass "a pinned shim keeps the direct-verb invocation (no 'task' inserted)" \
  || fail "pinned shim invocation wrong:\n$rep_cli"

# ── The bare-image error: workspace CLI unset, no tp anywhere ──────────────────
# With no /opt/taskpump mount (a custom runner) the bare default cannot resolve
# in a container. That must fail at STARTUP, before the session banner, with an
# error naming both fixes — an agent discovering its ledger CLI missing
# mid-session burns the whole iteration on a misconfiguration. The install
# mount is pinned to an absent path so a real /opt/taskpump on the host this
# suite runs on cannot leak into the fixture (hermeticity).
echo "--- bare default without tp on PATH (mount absent) ---"
NOMOUNT="$WORK/absent-install-mount"   # never created
NOTP="$WORK/no-tp-bin"; mkdir -p "$NOTP"
# Everything plan mode needs, minus tp: bash for run_ep's re-exec, tee and date
# for the startup banner the pinned-CLI contrast case reaches.
ln -s "$(command -v bash)" "$NOTP/bash"
ln -s "$(command -v tee)"  "$NOTP/tee"
ln -s "$(command -v date)" "$NOTP/date"
out_notp=$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan PATH="$NOTP" \
  TASKPUMP_INSTALL_MOUNT="$NOMOUNT" \
  TP_WORKSPACE="$R2/wt" TP_REPO_ROOT="$R2" TP_BRIEF="$R2/brief.md")
rc_notp=$?
[[ $rc_notp -eq 1 ]] \
  && pass "workspace CLI unset + no tp on PATH + no mount exits 1 (operator misconfiguration)" \
  || fail "missing-CLI run exited $rc_notp:\n$out_notp"
grep -q "task CLI 'tp' is not on PATH" <<<"$out_notp" \
  && pass "the error says what is missing" || fail "no missing-CLI diagnostic:\n$out_notp"
grep -q 'TASKPUMP_WORKSPACE_TASK_CLI' <<<"$out_notp" \
  && pass "the error names the config-key fix" || fail "error does not name TASKPUMP_WORKSPACE_TASK_CLI:\n$out_notp"
grep -q "provide 'tp' in the agent image" <<<"$out_notp" \
  && pass "the error names the provide-tp-in-the-image fix" || fail "error does not name the image fix:\n$out_notp"
grep -q 'TaskPump agent started' <<<"$out_notp" \
  && fail "the missing-CLI error fired after startup began (must be before the banner)" \
  || pass "the error fires before the startup banner — launch time, not mid-session"
# A configured CLI is exempt from the PATH probe: paths are resolved, not
# PATH-searched, so the same tp-less environment plans fine when the consumer
# pinned its shim.
out_pinned=$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan PATH="$NOTP" \
  TASKPUMP_INSTALL_MOUNT="$NOMOUNT" \
  TP_WORKSPACE="$R2/wt" TP_REPO_ROOT="$R2" TP_BRIEF="$R2/brief.md" \
  TASKPUMP_WORKSPACE_TASK_CLI=scripts/arachne-task)
grep -q "^task_cli=$R2/wt/scripts/arachne-task$" <<<"$(report "$out_pinned")" \
  && pass "a set workspace CLI is used as before even with no tp on PATH" \
  || fail "pinned CLI failed without tp on PATH:\n$out_pinned"

# ── The /opt/taskpump mount: tp on the agent PATH (G4.3) ───────────────────────
# The shipped runner bind-mounts the TaskPump installation read-only at
# /opt/taskpump, and the entrypoint prepends its bin to PATH before resolving
# the task CLI. Resolution order: explicit TASKPUMP_WORKSPACE_TASK_CLI, then tp
# on PATH (guaranteed by the mount), then the loud G1.6 error (unreachable with
# the shipped runner; kept for custom runners). TASKPUMP_INSTALL_MOUNT is the
# hermetic seam standing in for the fixed in-container mount path.
echo "--- the /opt/taskpump install mount (G4.3) ---"
FAKEINSTALL="$WORK/install-mount"; mkdir -p "$FAKEINSTALL/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >| "$FAKEINSTALL/bin/tp"
chmod +x "$FAKEINSTALL/bin/tp"
# Unset CLI + no tp on PATH + mount present: the mounted tp is found, where the
# identical environment without the mount exited 1 just above.
out_mnt=$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan PATH="$NOTP" \
  TASKPUMP_INSTALL_MOUNT="$FAKEINSTALL" \
  TP_WORKSPACE="$R2/wt" TP_REPO_ROOT="$R2" TP_BRIEF="$R2/brief.md")
rc_mnt=$?
rep_mnt=$(report "$out_mnt")
[[ $rc_mnt -eq 0 ]] \
  && pass "unset CLI + tp-less PATH plans fine once the install mount is present" \
  || fail "mounted-tp run exited $rc_mnt:\n$out_mnt"
grep -q '^task_cli=tp$' <<<"$rep_mnt" \
  && pass "the bare default still resolves as tp" || fail "task_cli wrong with mount:\n$rep_mnt"
grep -q "^task_cli_path=$FAKEINSTALL/bin/tp$" <<<"$rep_mnt" \
  && pass "the tp found is the MOUNTED one (\$mount/bin/tp), not some other" \
  || fail "task_cli_path is not the mounted tp:\n$rep_mnt"
grep -q '^task_cli_argv=tp task$' <<<"$rep_mnt" \
  && pass "the mounted tp is invoked as 'tp task <verb>'" \
  || fail "mounted-tp invocation wrong:\n$rep_mnt"
# The mount is a PREPEND: it outranks an image-baked tp already on PATH.
out_shadow=$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TASKPUMP_INSTALL_MOUNT="$FAKEINSTALL" \
  TP_WORKSPACE="$R2/wt" TP_REPO_ROOT="$R2" TP_BRIEF="$R2/brief.md")
grep -q "^task_cli_path=$FAKEINSTALL/bin/tp$" <<<"$(report "$out_shadow")" \
  && pass "the mounted tp outranks an image-baked tp (PATH prepend, not append)" \
  || fail "an image-baked tp shadowed the mount:\n$(report "$out_shadow")"
# An explicit pin still wins over the mount — the resolution order's first rung.
out_pinwin=$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan PATH="$NOTP" \
  TASKPUMP_INSTALL_MOUNT="$FAKEINSTALL" \
  TP_WORKSPACE="$R2/wt" TP_REPO_ROOT="$R2" TP_BRIEF="$R2/brief.md" \
  TASKPUMP_WORKSPACE_TASK_CLI=scripts/arachne-task)
rep_pinwin=$(report "$out_pinwin")
grep -q "^task_cli=$R2/wt/scripts/arachne-task$" <<<"$rep_pinwin" \
  && pass "an explicit TASKPUMP_WORKSPACE_TASK_CLI wins over the mounted tp" \
  || fail "the mount shadowed the consumer's pin:\n$rep_pinwin"
grep -q "^task_cli_argv=$R2/wt/scripts/arachne-task$" <<<"$rep_pinwin" \
  && pass "the winning pin keeps its direct-verb invocation" \
  || fail "pinned invocation wrong under the mount:\n$rep_pinwin"
# The natural spelling once the mount exists: pinning the MOUNTED tp by path.
# Basename keying must recognise it as tp and keep the `task` verb grammar —
# the literal-'tp' comparison would have taken the direct-verb branch and
# turned every safety-net call into a silent `... tp claim` no-op.
out_pinmnt=$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan PATH="$NOTP" \
  TASKPUMP_INSTALL_MOUNT="$FAKEINSTALL" \
  TP_WORKSPACE="$R2/wt" TP_REPO_ROOT="$R2" TP_BRIEF="$R2/brief.md" \
  TASKPUMP_WORKSPACE_TASK_CLI="$FAKEINSTALL/bin/tp")
rep_pinmnt=$(report "$out_pinmnt")
grep -q "^task_cli=$FAKEINSTALL/bin/tp$" <<<"$rep_pinmnt" \
  && pass "the mounted tp can be pinned by its absolute path" \
  || fail "pinned mounted tp resolved wrong:\n$rep_pinmnt"
grep -q "^task_cli_argv=$FAKEINSTALL/bin/tp task$" <<<"$rep_pinmnt" \
  && pass "a pinned mounted tp is still invoked as '<path>/tp task <verb>'" \
  || fail "pinned mounted tp lost the task-verb grammar:\n$rep_pinmnt"

# The TP_ spelling must work for EVERY key, not just the headline ones. The pump
# was exporting TP_TASKS_DIR / TP_AGENT_LOG_NAME / TP_GOAL_NOTE_NAME against an
# entrypoint that read only the TASKPUMP_ spelling of those three, so they were
# silently inert. A partial rule is worse than no rule.
rep_tp=$(report "$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TP_WORKSPACE="$R2/wt" TP_REPO_ROOT="$R2" TP_BRIEF="$R2/brief.md" \
  TP_TASKS_DIR="$R2/tasks" TP_SAFETY_TURNS=9 TP_CONTAINER_USER=agent \
  TP_WORKSPACE_TASK_CLI=bin/tp)")
grep -q "^tasks_dir=$R2/tasks$" <<<"$rep_tp"   && pass "TP_TASKS_DIR resolves"   || fail "TP_TASKS_DIR inert:\n$rep_tp"
grep -q '^safety_turns=9$' <<<"$rep_tp"        && pass "TP_SAFETY_TURNS resolves" || fail "TP_SAFETY_TURNS inert:\n$rep_tp"
grep -q '^container_user=agent$' <<<"$rep_tp"  && pass "TP_CONTAINER_USER resolves" || fail "TP_CONTAINER_USER inert:\n$rep_tp"
grep -q "^task_cli=$R2/wt/bin/tp$" <<<"$rep_tp" && pass "TP_WORKSPACE_TASK_CLI resolves" || fail "TP_WORKSPACE_TASK_CLI inert:\n$rep_tp"
# TP_AGENT_LOG_NAME / TP_GOAL_NOTE_NAME show up as the files that get written.
R2b=$(mk_ws tpnames)
out_tp=$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TP_WORKSPACE="$R2b/wt" TP_REPO_ROOT="$R2b" TP_BRIEF="$R2b/brief.md" \
  TP_TASK_ID=F9.1 TP_TASKS_DIR="$R2b/tasks" \
  TP_AGENT_LOG_NAME=.agent.log TP_GOAL_NOTE_NAME=.goal.md)
[[ -f "$R2b/wt/.agent.log" ]] && pass "TP_AGENT_LOG_NAME renames the agent log" \
  || fail "TP_AGENT_LOG_NAME inert (no $R2b/wt/.agent.log)"
grep -q "prompt_parts=$R2b/wt/.goal.md " <<<"$(report "$out_tp")" \
  && pass "TP_GOAL_NOTE_NAME renames the goal note" || fail "TP_GOAL_NOTE_NAME inert:\n$(report "$out_tp")"

# ...and the runner must actually carry both spellings across into the container,
# or resolving them in the entrypoint changes nothing in production.
for name in TASKPUMP_TASKS_DIR TP_TASKS_DIR TASKPUMP_AGENT_LOG_NAME TP_AGENT_LOG_NAME \
            TASKPUMP_GOAL_NOTE_NAME TP_GOAL_NOTE_NAME TASKPUMP_PRE_FLIGHT TP_PRE_FLIGHT; do
  grep -qF "$name" <<<"$(grep -A30 '^DEFAULT_PASSTHROUGH=' "$RUNNER")" \
    && pass "runner forwards $name when set" || fail "runner does not forward $name"
done

echo "--- stdin assembly ordering ---"
# Both note NAMES are pinned (G1.3 flips their .arachne-* defaults); the
# ordering and the convention-fallback mechanism are what these cases assert.
R3=$(mk_ws ordering)
printf 'resume preamble\n' >| "$R3/wt/.arachne-resume.md"
rep_ord=$(report "$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TP_WORKSPACE="$R3/wt" TP_REPO_ROOT="$R3" TP_BRIEF="$R3/brief.md" \
  TP_RESUME_NOTE="$R3/wt/.arachne-resume.md" \
  TP_TASK_ID=F9.1 TASKPUMP_TASKS_DIR="$R3/tasks" \
  TASKPUMP_GOAL_NOTE_NAME=.arachne-goal.md)")
grep -q "prompt_parts=$R3/wt/.arachne-goal.md $R3/wt/.arachne-resume.md $R3/brief.md" <<<"$rep_ord" \
  && pass "stdin order is goal, then resume note, then brief" \
  || fail "stdin assembly order wrong:\n$rep_ord"
# The resume note is also findable by convention when the env path does not
# resolve inside the container. The conventional NAME is the configured one.
rep_conv=$(report "$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TP_WORKSPACE="$R3/wt" TP_REPO_ROOT="$R3" TP_BRIEF="$R3/brief.md" \
  TP_RESUME_NOTE=/host/only/path/.arachne-resume.md \
  TASKPUMP_RESUME_NOTE_NAME=.arachne-resume.md)")
grep -q "$R3/wt/.arachne-resume.md" <<<"$rep_conv" \
  && pass "an unresolvable resume path falls back to the conventional workspace file" \
  || fail "resume-note fallback did not fire:\n$rep_conv"
# A brief given relative to the repo root resolves.
rep_rel=$(report "$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TP_WORKSPACE="$R3/wt" TP_REPO_ROOT="$R3" TP_BRIEF=brief.md)")
grep -q "$R3/brief.md" <<<"$rep_rel" \
  && pass "a repo-root-relative brief path resolves" || fail "relative brief did not resolve:\n$rep_rel"
# A missing brief is a configuration error, not a silent empty prompt.
out_nobrief=$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TP_WORKSPACE="$R3/wt" TP_REPO_ROOT="$R3" TP_BRIEF=nope.md)
[[ $? -eq 1 ]] && grep -q 'brief not found' <<<"$out_nobrief" \
  && pass "a missing brief exits 1 with a named reason" || fail "missing brief not rejected:\n$out_nobrief"

echo "--- pre-flight hook ---"
R4=$(mk_ws hook)
HOOK="$R4/hook.sh"
cat >| "$HOOK" <<EOF
#!/usr/bin/env bash
: >| "$R4/hook-ran"
printf '%s\n' "\$WORKSPACE_PATH" >| "$R4/hook-workspace"
printf '%s\n' "\$TASKPUMP_TASK_ID" >| "$R4/hook-task"
EOF
chmod +x "$HOOK"
out_hook=$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=preflight \
  TP_WORKSPACE="$R4/wt" TP_REPO_ROOT="$R4" TP_BRIEF="$R4/brief.md" \
  TP_TASK_ID=F9.1 TASKPUMP_TASKS_DIR="$R4/tasks" \
  TASKPUMP_CONTAINER_HOME="$R4/home" TASKPUMP_PRE_FLIGHT="$HOOK")
rc_hook=$?
[[ $rc_hook -eq 0 ]] && pass "preflight mode exits 0 with a hook configured" \
  || fail "preflight mode rc=$rc_hook:\n$out_hook"
[[ -f "$R4/hook-ran" ]] && pass "the pre-flight hook is executed" || fail "hook marker was never written"
[[ "$(cat "$R4/hook-workspace" 2>/dev/null)" == "$R4/wt" ]] \
  && pass "the hook receives WORKSPACE_PATH" || fail "hook did not receive WORKSPACE_PATH"
[[ "$(cat "$R4/hook-task" 2>/dev/null)" == "F9.1" ]] \
  && pass "the hook receives TASKPUMP_TASK_ID" || fail "hook did not receive TASKPUMP_TASK_ID"
grep -q "^pre_flight=hook:$HOOK$" <<<"$(report "$out_hook")" \
  && pass "the plan names the configured hook" || fail "plan did not name the hook:\n$out_hook"

# A hook that fails must abort with EX_TEMPFAIL, before any heartbeat.
BADHOOK="$R4/bad.sh"
printf '#!/usr/bin/env bash\nexit 4\n' >| "$BADHOOK"; chmod +x "$BADHOOK"
out_bad=$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=preflight \
  TP_WORKSPACE="$R4/wt" TP_REPO_ROOT="$R4" TP_BRIEF="$R4/brief.md" \
  TASKPUMP_CONTAINER_HOME="$R4/home" TASKPUMP_PRE_FLIGHT="$BADHOOK")
[[ $? -eq 75 ]] && pass "a failing pre-flight hook exits 75 (EX_TEMPFAIL)" \
  || fail "failing hook did not exit 75:\n$out_bad"
out_missing=$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=preflight \
  TP_WORKSPACE="$R4/wt" TP_REPO_ROOT="$R4" TP_BRIEF="$R4/brief.md" \
  TASKPUMP_CONTAINER_HOME="$R4/home" TASKPUMP_PRE_FLIGHT="$R4/does-not-exist")
[[ $? -eq 75 ]] && pass "a non-executable pre-flight hook exits 75" \
  || fail "missing hook did not exit 75:\n$out_missing"

echo "--- no-hook fallback ---"
R5=$(mk_ws nohook)
rep_none=$(report "$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TP_WORKSPACE="$R5/wt" TP_REPO_ROOT="$R5" TP_BRIEF="$R5/brief.md")")
grep -q '^pre_flight=none$' <<<"$rep_none" \
  && pass "no hook and no legacy markers ⇒ no pre-flight runs" || fail "expected pre_flight=none:\n$rep_none"
# Transitional compatibility: a pre-hook consumer image is detected by its marker
# file and still gets the old inline pre-flight.
: >| "$R5/claude-settings-auto.json"
rep_leg=$(report "$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TP_WORKSPACE="$R5/wt" TP_REPO_ROOT="$R5" TP_BRIEF="$R5/brief.md")")
grep -q '^pre_flight=legacy-inline$' <<<"$rep_leg" \
  && pass "legacy markers with no hook ⇒ the transitional inline pre-flight" || fail "expected legacy-inline:\n$rep_leg"
# An explicit hook always wins over the legacy markers.
rep_win=$(report "$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TP_WORKSPACE="$R5/wt" TP_REPO_ROOT="$R5" TP_BRIEF="$R5/brief.md" \
  TASKPUMP_PRE_FLIGHT="$HOOK")")
grep -q "^pre_flight=hook:$HOOK$" <<<"$rep_win" \
  && pass "a configured hook wins over the legacy markers" || fail "legacy path won over the hook:\n$rep_win"

# ── runner.sh: the launch contract ─────────────────────────────────────────────
echo "--- runner.sh launch contract ---"
R6=$(mk_ws runner)
mkdir -p "$R6/ops" "$R6/.git"
# The install-mount source the runner will resolve: its own realpath, up two
# levels — the same derivation bin/tp uses for its libexec (G4.3). Computed the
# runner's way (readlink -f) rather than reusing TP_ROOT, so a symlinked
# checkout normalizes identically on both sides of the compare.
TP_MOUNT_SRC="$(CDPATH= cd -- "$(dirname "$(readlink -f "$RUNNER")")/../.." && pwd)"
norm_line() { local s="${1//$R6/@R@}"; printf '%s' "${s//$TP_MOUNT_SRC/@TP@}"; }
launch_line() {  # launch_line <extra var=value>...
  run_runner launch \
    DOCKER=/bin/echo \
    TP_WORKSPACE="$R6/wt" TP_REPO_ROOT="$R6" \
    TP_CONTAINER_NAME=tp-agent-feat-f9 TP_IMAGE=agentimg \
    TP_BRANCH=feat/f9 TP_TASK_ID=F9.1 TP_PHASE=F9 \
    TP_BRIEF="$R6/brief.md" TP_MODEL=opus TP_MAX_TURNS=600 \
    TP_CLAUDE_DIR="$R6/claude-home" TP_CLAUDE_JSON="$R6/claude.json" \
    "$@"
}
got=$(launch_line); rc=$?
got_norm=$(norm_line "$got")
want='run --rm -d --init --name tp-agent-feat-f9 --cap-add NET_ADMIN --memory 3g --memory-swap 5g'
want+=' -e GITHUB_TOKEN -e WORKSPACE_PATH=@R@/wt -e REPO_ROOT=@R@'
want+=' -e ARACHNE_BRIEF=@R@/brief.md -e ARACHNE_RESUME_NOTE= -e ARACHNE_TASK_ID=F9.1'
want+=' -e ARACHNE_PHASE=F9 -e MAX_TURNS=600 -e AGENT_MODEL=opus'
want+=' -e TASKPUMP_WORKSPACE_PATH=@R@/wt -e TASKPUMP_REPO_ROOT=@R@ -e TASKPUMP_LEDGER_REPO=@R@/ops'
want+=' -e TASKPUMP_BRIEF=@R@/brief.md -e TASKPUMP_RESUME_NOTE= -e TASKPUMP_TASK_ID=F9.1'
want+=' -e TASKPUMP_PHASE=F9 -e TASKPUMP_BRANCH=feat/f9 -e TASKPUMP_MAX_TURNS=600'
want+=' -e TASKPUMP_AGENT_MODEL=opus'
want+=' -v @R@/claude-home:/tmp/claude-home:ro'
want+=' -v @R@/claude.json:/tmp/claude-home-json/.claude.json:ro'
# The TaskPump installation rides along read-only so tp is on the agent's PATH
# (G4.3); the source is the runner's own installation root.
want+=' -v @TP@:/opt/taskpump:ro'
want+=' -v @R@:@R@:ro -v @R@/.git:@R@/.git -v @R@/wt:@R@/wt -v @R@/ops:@R@/ops'
# The trailing /entrypoint.sh is the bare ENTRYPOINT default (this launch
# passes no TP_ENTRYPOINT): the shipped runner's own entrypoint at the path
# the image contract bakes it (G1.5; docs/RUNNERS.md §4.0). Arachne's
# /entrypoint-parallel.sh layout arrives only via its conf pin; the override
# path is covered separately below.
want+=' -w @R@/wt agentimg /entrypoint.sh'
[[ $rc -eq 0 ]] && pass "launch exits 0 and prints the container id" || fail "launch rc=$rc:\n$got"
if [[ "$got_norm" == "$want" ]]; then
  pass "launch reproduces the golden docker run line exactly"
else
  fail "launch line drifted.\n--- want ---\n$want\n--- got ---\n$got_norm"
fi

# The individual invariants the golden line encodes, asserted separately so a
# failure says which one broke rather than just "the line changed".
for probe in \
  '--cap-add NET_ADMIN' '--memory 3g' '--memory-swap 5g' '--rm -d' '--init' \
  "-v @R@:@R@:ro" "-v @R@/.git:@R@/.git" "-v @R@/wt:@R@/wt" "-v @R@/ops:@R@/ops" \
  "-v @TP@:/opt/taskpump:ro"; do
  grep -qF -- "$probe" <<<"$got_norm" && pass "launch line carries '$probe'" \
    || fail "launch line is missing '$probe'"
done
# The installation mount must never be writable: an agent that can edit the
# host's TaskPump checkout edits the supervisor supervising it. With :ro the
# next character after the destination is ':', so space-or-EOL is the RW shape.
if grep -qE -- ':/opt/taskpump( |$)' <<<"$got_norm"; then
  fail "the /opt/taskpump installation mount lost its :ro"
else
  pass "the /opt/taskpump installation mount is read-only"
fi
# The read-only primary must not have regressed to a blanket RW mount.
#
# The terminator matters. `( |$)` is what distinguishes a blanket `-v X:X` from
# the legitimate `-v X:X:ro`; a laxer terminator such as `[^:]` reads the `:` of
# `:ro` as the "something other than a colon" it is looking for and condemns
# correct code. So the predicate gets a positive control before it is trusted:
# a guard that has never been shown to go red is not a guard, it is a comment.
BLANKET_RE="-v @R@:@R@( |$)"
grep -qE -- "$BLANKET_RE" <<<"-v @R@:@R@ -v @R@/.git:@R@/.git -w @R@ img /e.sh" \
  && pass "control: the blanket-mount predicate fires on a mid-line blanket mount" \
  || fail "control: the blanket-mount predicate MISSED a real blanket mount — the guard is inert"
grep -qE -- "$BLANKET_RE" <<<"-v @R@/.git:@R@/.git -v @R@:@R@" \
  && pass "control: it also fires when the blanket mount ends the line" \
  || fail "control: the predicate misses a line-terminal blanket mount"
grep -qE -- "$BLANKET_RE" <<<"-v @R@:@R@:ro -v @R@/.git:@R@/.git" \
  && fail "control: the predicate condemns the correct :ro mount (terminator too lax)" \
  || pass "control: it does not fire on the correct :ro mount"
if grep -qE -- "$BLANKET_RE" <<<"$got_norm"; then
  fail "blanket RW primary mount re-introduced (the read-only mount regressed)"
else
  pass "no blanket RW primary mount"
fi

# The ledger-is-primary shape (G0.4). TaskPump's own dogfood keeps the ledger
# tasks/ in the code repo, so TP_LEDGER_REPO == TP_REPO_ROOT. Docker rejects
# duplicate mount points, so that shape must collapse the :ro primary and the
# RW ledger mounts into a single RW mount of the checkout — here the blanket
# mount IS the contract, and the .git overlay is subsumed by it.
got=$(launch_line TP_LEDGER_REPO="$R6")
got_norm=$(norm_line "$got")
grep -qE -- "$BLANKET_RE" <<<"$got_norm" \
  && pass "ledger==primary mounts the checkout read-write" \
  || fail "ledger==primary is missing the RW checkout mount:\n$got_norm"
grep -qF -- "-v @R@:@R@:ro" <<<"$got_norm" \
  && fail "ledger==primary still emits the :ro primary mount (duplicate mount point)" \
  || pass "ledger==primary drops the :ro primary mount"
grep -qF -- "-v @R@/.git:@R@/.git" <<<"$got_norm" \
  && fail "ledger==primary still emits the .git overlay (subsumed by the RW root)" \
  || pass "ledger==primary drops the redundant .git overlay"
grep -qF -- "-v @R@/wt:@R@/wt" <<<"$got_norm" \
  && pass "ledger==primary keeps the workspace mount" \
  || fail "ledger==primary lost the workspace mount:\n$got_norm"
mount_count=$(grep -oF -- "-v @R@:@R@" <<<"$got_norm" | wc -l)
[[ "$mount_count" -eq 1 ]] \
  && pass "ledger==primary mounts the checkout exactly once" \
  || fail "ledger==primary mounts the checkout $mount_count times:\n$got_norm"
grep -qF -- "-e TASKPUMP_LEDGER_REPO=@R@ " <<<"$got_norm" \
  && pass "ledger==primary forwards TASKPUMP_LEDGER_REPO as the checkout" \
  || fail "TASKPUMP_LEDGER_REPO env wrong in ledger==primary shape:\n$got_norm"

got=$(launch_line TP_ENTRYPOINT=/tp-entrypoint.sh TP_IMAGE=other TP_MEMORY_MAX=8g)
got_norm=$(norm_line "$got")
grep -qF -- 'other /tp-entrypoint.sh' <<<"$got_norm" \
  && pass "TP_IMAGE and TP_ENTRYPOINT are honoured, in that order, last" \
  || fail "image/entrypoint override wrong:\n$got_norm"
grep -qF -- '--memory 8g' <<<"$got_norm" && pass "TP_MEMORY_MAX is honoured" || fail "memory override ignored"

got=$(launch_line TP_CONTAINER_RUN_USER=1000:1000)
grep -qF -- '--user 1000:1000' <<<"$got" && pass "TP_CONTAINER_RUN_USER emits --user when set" \
  || fail "--user not emitted:\n$got"
got=$(launch_line)
grep -qF -- '--user' <<<"$got" && fail "--user emitted by default (root is required for NET_ADMIN)" \
  || pass "no --user by default"

got=$(launch_line TASKPUMP_PRE_FLIGHT=/preflight.sh)
grep -qF -- '-e TASKPUMP_PRE_FLIGHT' <<<"$got" \
  && pass "a set passthrough variable is forwarded into the container" \
  || fail "passthrough did not forward TASKPUMP_PRE_FLIGHT:\n$got"
# By name only: the value rides docker's own environment, never its argv (#14).
grep -qF -- '-e TASKPUMP_PRE_FLIGHT=' <<<"$got" \
  && fail "passthrough embeds the variable's VALUE in docker argv" \
  || pass "passthrough forwards the name only; the value stays in the environment"

# Legacy-only inputs must produce the same line as canonical-only inputs.
got_legacy=$(run_runner launch DOCKER=/bin/echo \
  WORKSPACE_PATH="$R6/wt" REPO_ROOT="$R6" \
  ARACHNE_CONTAINER_NAME=tp-agent-feat-f9 ARACHNE_IMAGE=agentimg \
  ARACHNE_BRANCH=feat/f9 ARACHNE_TASK_ID=F9.1 ARACHNE_PHASE=F9 \
  ARACHNE_BRIEF="$R6/brief.md" AGENT_MODEL=opus MAX_TURNS=600 \
  CLAUDE_DIR="$R6/claude-home" CLAUDE_JSON="$R6/claude.json")
[[ "$(norm_line "$got_legacy")" == "$want" ]] \
  && pass "legacy-only runner inputs produce the identical launch line" \
  || fail "legacy runner inputs diverged:\n$(norm_line "$got_legacy")"

echo "--- runner.sh error + stop contract ---"
out=$(run_runner launch DOCKER=/bin/echo TP_WORKSPACE="$R6/wt" TP_REPO_ROOT="$R6" \
  TP_CONTAINER_NAME=c1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'TP_IMAGE is required' <<<"$out" \
  && pass "a missing TP_IMAGE fails loudly rather than defaulting" || fail "missing image not rejected:\n$out"
out=$(run_runner launch DOCKER=/bin/echo TP_REPO_ROOT="$R6" TP_CONTAINER_NAME=c1 TP_IMAGE=i); rc=$?
[[ $rc -ne 0 ]] && grep -q 'TP_WORKSPACE' <<<"$out" \
  && pass "a missing workspace fails loudly" || fail "missing workspace not rejected:\n$out"

# A runner copied away from its installation has nothing to mount at
# /opt/taskpump. It must refuse the launch loudly, naming the resolved path —
# otherwise the failure surfaces much later, inside the container, as a
# missing task CLI (G4.3).
LONE="$WORK/lone-runner"; mkdir -p "$LONE"
cp "$RUNNER" "$LONE/runner.sh"
out=$(
  # shellcheck disable=SC2086
  unset $CONTRACT_VARS
  export DOCKER=/bin/echo TP_WORKSPACE="$R6/wt" TP_REPO_ROOT="$R6" \
         TP_CONTAINER_NAME=c1 TP_IMAGE=i
  bash "$LONE/runner.sh" launch 2>&1
); rc=$?
[[ $rc -ne 0 ]] && grep -q 'no tp at' <<<"$out" \
  && pass "a relocated runner refuses to launch rather than mount a tp-less directory" \
  || fail "relocated runner did not fail loudly (rc=$rc):\n$out"
grep -q '/opt/taskpump' <<<"$out" \
  && pass "the relocation error names the mount it could not honour" \
  || fail "relocation error does not name /opt/taskpump:\n$out"

FAKE_DOCKER="$WORK/docker-fail"
cat >| "$FAKE_DOCKER" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "run" ]] && { echo "docker: image not found" >&2; exit 125; }
exit 0
EOF
chmod +x "$FAKE_DOCKER"
out=$(run_runner launch DOCKER="$FAKE_DOCKER" TP_WORKSPACE="$R6/wt" TP_REPO_ROOT="$R6" \
  TP_CONTAINER_NAME=c1 TP_IMAGE=i); rc=$?
[[ $rc -ne 0 ]] && grep -q 'docker run failed' <<<"$out" \
  && pass "a failed docker run exits non-zero with a reason on stderr" || fail "run failure not surfaced (rc=$rc):\n$out"

STOP_LOG="$WORK/stop.log"
FAKE_STOP="$WORK/docker-stop"
cat >| "$FAKE_STOP" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STOP_LOG"
exit 0
EOF
chmod +x "$FAKE_STOP"
out=$(run_runner stop DOCKER="$FAKE_STOP" TP_CONTAINER_NAME=tp-agent-feat-f9); rc=$?
[[ $rc -eq 0 ]] && grep -qF 'stop tp-agent-feat-f9' "$STOP_LOG" \
  && pass "stop calls docker stop with the container name" || fail "stop did not dispatch (rc=$rc):\n$out"

FAKE_GONE="$WORK/docker-gone"
cat >| "$FAKE_GONE" <<'EOF'
#!/usr/bin/env bash
echo "Error response from daemon: No such container: ghost" >&2
exit 1
EOF
chmod +x "$FAKE_GONE"
out=$(run_runner stop DOCKER="$FAKE_GONE" TP_CONTAINER_NAME=ghost); rc=$?
[[ $rc -eq 0 ]] && pass "stopping a container that is already gone succeeds (idempotent)" \
  || fail "stop was not idempotent (rc=$rc):\n$out"

out=$(run_runner bogus DOCKER=/bin/echo); rc=$?
[[ $rc -eq 2 ]] && pass "an unknown verb exits 2 (bad usage)" || fail "unknown verb rc=$rc (expected 2)"

# ── G4.3 end to end (stubbed): a container claims with the mounted tp ──────────
# The acceptance shape: a container launched by the reference runner can run
# `tp task claim` against the mounted ledger with NO vendored CLI in the
# workspace. Two hermetic halves of one path: the runner composes the argv that
# mounts this installation and the ledger (stub docker echoes it back), and the
# entrypoint — resolving in exactly the environment that argv creates: no
# workspace CLI pinned, the install mount pointing at this very checkout —
# assembles a session script whose safety-net calls are `tp task claim` /
# `tp task heartbeat` against the ledger's tasks dir. No ledger verb is
# executed; composition is the assertion.
echo "--- G4.3 end to end: claim via the mounted tp (stubbed) ---"
R7=$(mk_ws mountedclaim)
mkdir -p "$R7/ops/tasks" "$R7/.git" "$R7/home"
mv "$R7/tasks/F9.1.md" "$R7/ops/tasks/F9.1.md"
argv=$(run_runner launch DOCKER=/bin/echo \
  TP_WORKSPACE="$R7/wt" TP_REPO_ROOT="$R7" TP_LEDGER_REPO="$R7/ops" \
  TP_CONTAINER_NAME=tp-agent-feat-f9 TP_IMAGE=agentimg \
  TP_BRANCH=feat/f9 TP_TASK_ID=F9.1 TP_PHASE=F9 \
  TP_BRIEF="$R7/brief.md" \
  TP_CLAUDE_DIR="$R7/claude-home" TP_CLAUDE_JSON="$R7/claude.json"); rc=$?
[[ $rc -eq 0 ]] \
  && pass "launch composes with no vendored CLI and no TASKPUMP_WORKSPACE_TASK_CLI pin" \
  || fail "launch failed rc=$rc:\n$argv"
grep -qF -- "-v $TP_MOUNT_SRC:/opt/taskpump:ro" <<<"$argv" \
  && pass "argv mounts THIS installation read-only at /opt/taskpump" \
  || fail "argv does not mount the installation:\n$argv"
grep -qF -- "-v $R7/ops:$R7/ops" <<<"$argv" \
  && pass "argv mounts the ledger checkout read-write" \
  || fail "argv is missing the ledger mount:\n$argv"
grep -qF -- "-e TASKPUMP_LEDGER_REPO=$R7/ops" <<<"$argv" \
  && pass "argv hands the entrypoint the ledger path" \
  || fail "argv is missing the ledger env:\n$argv"
grep -qF -- '-e TASKPUMP_WORKSPACE_TASK_CLI' <<<"$argv" \
  && fail "argv pins a workspace task CLI (this shape must rely on the mount)" \
  || pass "argv pins no workspace task CLI — resolution rides the mount"
# The entrypoint half, in the environment that argv creates.
out_e2e=$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=script \
  TASKPUMP_INSTALL_MOUNT="$TP_MOUNT_SRC" \
  TP_WORKSPACE="$R7/wt" TP_REPO_ROOT="$R7" TP_LEDGER_REPO="$R7/ops" \
  TP_BRIEF="$R7/brief.md" TP_TASK_ID=F9.1 TP_PHASE=F9 \
  TASKPUMP_CONTAINER_HOME="$R7/home"); rc=$?
[[ $rc -eq 0 ]] \
  && pass "the entrypoint assembles the session with only the mounted tp" \
  || fail "script mode failed (rc=$rc):\n$out_e2e"
grep -qF "tp task claim 'F9.1' --branch" <<<"$out_e2e" \
  && pass "the safety-net claim is 'tp task claim' via the mounted tp" \
  || fail "no 'tp task claim' in the session script:\n$out_e2e"
grep -qF "tp task heartbeat 'F9.1' --start" <<<"$out_e2e" \
  && pass "the start heartbeat rides the same 'tp task' invocation" \
  || fail "no 'tp task heartbeat --start' in the session script:\n$out_e2e"
grep -qF "export TASKPUMP_TASKS_DIR='$R7/ops/tasks'" <<<"$out_e2e" \
  && pass "the claim targets the mounted ledger's tasks dir" \
  || fail "session script does not export the ledger tasks dir:\n$out_e2e"
# The grammar the script composes must be one the mounted tp actually answers:
# `tp` dispatches a `task` subcommand. Read-only probe — no ledger verb runs.
"$TP_MOUNT_SRC/bin/tp" help 2>/dev/null | grep -qE '^\s+task\b' \
  && pass "the mounted tp dispatches a 'task' subcommand (the composed grammar exists)" \
  || fail "the mounted tp at $TP_MOUNT_SRC/bin/tp does not answer 'tp task'"

# ── Shipped prompt templates ───────────────────────────────────────────────────
# The pump refuses to start without a brief template, so the shipped defaults are
# what keeps a fresh consumer from being dead on arrival. Two things must hold:
# they render with no placeholder left behind, and they stay generic — the moment
# one names a build system, the next consumer inherits a lie.
echo "--- shipped templates ---"
BRIEF_T="$TP_ROOT/templates/phase-drain-brief.md"
RESUME_T="$TP_ROOT/templates/resume-note.md"
[[ -f "$BRIEF_T" ]]  && pass "templates/phase-drain-brief.md ships"  || fail "no templates/phase-drain-brief.md"
[[ -f "$RESUME_T" ]] && pass "templates/resume-note.md ships"        || fail "no templates/resume-note.md"

# placeholders_in <file> — the distinct {{NAME}} tokens a template uses.
# LC_ALL=C pins the collation: the recorded want-lists below are byte order,
# and an unpinned sort flips TASK_CLI/TASK_CLI_NAME under UTF-8 locales.
placeholders_in() { grep -oE '\{\{[A-Z_]+\}\}' "$1" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'; }

got=$(placeholders_in "$BRIEF_T")
want='{{BASE}} {{DEPENDS_ON}} {{PHASE}} {{PROJECT_BRIEF}} {{TASK_CLI_NAME}} {{TASK_CLI}} {{TASK_DIR}} {{VERIFY_CMDS}}'
[[ "$got" == "$want" ]] && pass "brief template uses exactly the placeholders the pump substitutes" \
  || fail "brief placeholder set drifted.\n  want: $want\n  got:  $got"

got=$(placeholders_in "$RESUME_T")
want='{{BRANCH}} {{COMMITS}} {{DIFF_STAT}} {{PHASE}} {{STATUS_SHORT}} {{TASK_CLI_NAME}} {{TASK_CLI}} {{TASK_FILE}} {{TASK_ID}} {{VERIFY_CMDS}}'
[[ "$got" == "$want" ]] && pass "resume template uses exactly the documented placeholder set" \
  || fail "resume placeholder set drifted.\n  want: $want\n  got:  $got"
# BUILD_GATE means the merge queue's gate (TASKPUMP_BUILD_GATE). Reusing the name
# for the per-task verify commands would give one tool two meanings for it.
if grep -q '{{BUILD_GATE}}' "$RESUME_T" "$BRIEF_T"; then
  fail "a template uses {{BUILD_GATE}}, which collides with TASKPUMP_BUILD_GATE — use {{VERIFY_CMDS}}"
else
  pass "no template reuses {{BUILD_GATE}} for the per-task verify commands"
fi

# Every placeholder must be documented, and every documented one must be used.
for ph in $(placeholders_in "$BRIEF_T") $(placeholders_in "$RESUME_T"); do
  grep -qF "\`$ph\`" "$TP_ROOT/templates/README.md" \
    || fail "$ph is used by a template but not documented in templates/README.md"
done
pass "every template placeholder is documented in templates/README.md"

# Render the brief with the pump's own algorithm (sed for the scalars, whole-line
# replacement for the blocks) and assert nothing is left unsubstituted. The
# scalar set mirrors tp-pump's render map: PHASE, BASE, TASK_CLI, TASK_CLI_NAME,
# TASK_DIR, and VERIFY_CMDS (a semicolon-joined single line via apl_join_commands);
# DEPENDS_ON and PROJECT_BRIEF are whole-line blocks. VERIFY_CMDS is non-empty
# here, so the {{#VERIFY_CMDS}} section markers are simply dropped, mirroring
# the renderer's kept-section path (G1.7); the dropped-section path is covered
# by the renderer-contract suite in test-tp-pump.sh.
DEPS_F="$WORK/deps.txt"
printf 'Waits on F54.2 (another worktree).\nWaits on F56.1.\n' >| "$DEPS_F"
PROJ_F="$WORK/project-brief.txt"
printf 'Read the project docs before starting.\n' >| "$PROJ_F"
RENDERED="$WORK/brief-rendered.md"
sed -e 's/{{PHASE}}/F55/g' \
    -e 's/{{BASE}}/main/g' \
    -e 's|{{TASK_CLI}}|scripts/arachne-task|g' \
    -e 's/{{TASK_CLI_NAME}}/arachne-task/g' \
    -e 's|{{TASK_DIR}}|ops/task-loop/tasks|g' \
    -e 's/{{VERIFY_CMDS}}/cargo fmt --check; cargo clippy/g' \
    -e '/^{{#[A-Z_]*}}$/d' \
    -e '/^{{\/[A-Z_]*}}$/d' \
    "$BRIEF_T" \
  | awk -v df="$DEPS_F" 'index($0, "{{DEPENDS_ON}}") { while ((getline line < df) > 0) print line; close(df); next } {print}' \
  | awk -v pf="$PROJ_F" 'index($0, "{{PROJECT_BRIEF}}") { while ((getline line < pf) > 0) print line; close(pf); next } {print}' \
  >| "$RENDERED"
if grep -q '{{' "$RENDERED"; then
  fail "brief left unsubstituted placeholders: $(grep -o '{{[A-Z_]*}}' "$RENDERED" | sort -u | tr '\n' ' ')"
else
  pass "brief renders with no placeholder left behind"
fi
grep -q 'drain phase F55' "$RENDERED" && pass "brief substitutes {{PHASE}} in prose" || fail "{{PHASE}} not substituted"
grep -q 'Waits on F56.1' "$RENDERED" && pass "brief expands {{DEPENDS_ON}} to the full block" \
  || fail "{{DEPENDS_ON}} block not expanded"
grep -q '{{DEPENDS_ON}}' "$RENDERED" && fail "the {{DEPENDS_ON}} line survived expansion" \
  || pass "the {{DEPENDS_ON}} line is consumed by its block"

# Genericness. A shipped default that names cargo, npm, or a consumer's repo
# layout is a template only one project can use.
for word in cargo clippy rustc npm vitest playwright pytest 'ops/planning' 'ops/task-loop' arachne Arachne; do
  hits=$(grep -lF "$word" "$BRIEF_T" "$RESUME_T" 2>/dev/null)
  [[ -n "$hits" ]] && fail "shipped template names '$word' (must stay tool-agnostic): $hits"
done
pass "shipped templates name no build tool, test runner, or consumer repo layout"

# ── No subreaping intermediary in the session launch chain (issue #15) ─────────
# su(1) sets itself as a child subreaper, so orphaned tool subprocesses of the
# many-hour agent session reparented to it and were never reaped — zombies
# accumulated at the agent's tool-call rate. The contract: the privilege drop
# EXECS (setpriv), the script rides a file rather than a -c argv, and the
# runner installs tini as PID 1 (`--init`, asserted in the golden launch line
# above) to adopt and reap the orphans. runuser shares su's su-common.c and
# subreaps the same way, so it is equally banned from the session launch.
echo "--- session launch chain (issue #15) ---"
SUBREAP_RE='\b(su|runuser)\b[^|]*(DEV_SESSION_SCRIPT|SESSION_SCRIPT_FILE|SESSION_LAUNCH)'
# Positive controls first: the predicate must fire on both historical shapes
# before its silence is trusted.
grep -qE -- "$SUBREAP_RE" <<<'timeout 5 su "$CONTAINER_USER" -c "$DEV_SESSION_SCRIPT"' \
  && pass "control: the subreaper predicate fires on the su -c launch" \
  || fail "control: the subreaper predicate MISSED the su -c launch — the guard is inert"
grep -qE -- "$SUBREAP_RE" <<<'exec runuser -u dev -- bash "$SESSION_SCRIPT_FILE"' \
  && pass "control: it also fires on a runuser file launch" \
  || fail "control: the predicate misses a runuser launch"
grep -qE -- "$SUBREAP_RE" <<<'exec setpriv --reuid dev bash "$SESSION_SCRIPT_FILE"' \
  && fail "control: the predicate condemns the setpriv launch" \
  || pass "control: it does not fire on the setpriv launch"
if grep -vE '^[[:space:]]*#' "$EP" | grep -qE -- "$SUBREAP_RE"; then
  fail "a subreaping intermediary (su/runuser) launches the session (issue #15)"
else
  pass "no su/runuser touches the session launch chain"
fi
grep -qE -- 'setpriv --reuid' "$EP" \
  && pass "the session privilege drop is setpriv (execs; leaves no intermediary)" \
  || fail "entrypoint.sh does not drop privileges with setpriv"
grep -qE 'bash "\$SESSION_SCRIPT_FILE"' "$EP" \
  && pass "the session script runs from a file, not a -c argv" \
  || fail "the session script is not launched from a file"
# su also chose the session identity; setpriv does not, so losing su silently
# inherits root's HOME unless the launch sets it — and the agent's ~/.claude
# resolution rides on it.
grep -qE 'HOME="\$CONTAINER_HOME"' "$EP" \
  && pass "the launch sets the session user's HOME explicitly" \
  || fail "the launch does not set HOME (setpriv would inherit root's)"

# ── Secrets never reach argv (issue #14) ───────────────────────────────────────
# The token rides the environment end to end: docker -e forwards it by name,
# the privilege drop passes it through, and git reads it via a credential
# helper at use time. Neither the assembled session script (once the argv of a
# many-hour su process; a root-owned file since issue #15) nor the helper text
# may carry the VALUE — /proc/<pid>/cmdline is world-readable, and one drain
# exposed a live token there for 2.5 hours.
echo "--- secrets stay out of argv ---"
CANARY='gho_canary_value_must_not_appear'
RS=$(mk_ws secrets)
out_script=$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=script GITHUB_TOKEN="$CANARY" \
  TP_WORKSPACE="$RS/wt" TP_REPO_ROOT="$RS" TP_BRIEF="$RS/brief.md" \
  TP_TASK_ID=F9.1 TP_PHASE=F9 TASKPUMP_TASKS_DIR="$RS/tasks" \
  TASKPUMP_CONTAINER_HOME="$RS/home")
rc_script=$?
[[ $rc_script -eq 0 ]] \
  && pass "TEST_MODE=script renders the session script and exits 0" \
  || fail "TEST_MODE=script failed (rc=$rc_script): $out_script"
if grep -qF "$CANARY" <<<"$out_script"; then
  fail "the token VALUE appears in the session script or credential helper (argv leak)"
else
  pass "the token value appears nowhere in the assembled session script"
fi
grep -q 'export GITHUB_TOKEN$' <<<"$out_script" \
  && pass "the session script re-exports GITHUB_TOKEN by name only" \
  || fail "the session script does not re-export GITHUB_TOKEN by bare name"
grep -qF 'password=$GITHUB_TOKEN' <<<"$out_script" \
  && pass "the credential helper reads the token from the environment at use time" \
  || fail "the credential helper does not reference \$GITHUB_TOKEN by name"

# The runner's side of the same rule, asserted statically like the permission
# posture above: no executable line may put a value after -e for the token or
# the passthrough set.
if grep -vE '^[[:space:]]*#' "$RUNNER" | grep -qE -- '-e GITHUB_TOKEN='; then
  fail "runner.sh interpolates GITHUB_TOKEN's value into docker argv (must be bare -e GITHUB_TOKEN)"
else
  pass "runner.sh forwards GITHUB_TOKEN with a bare -e (value stays in the environment)"
fi
if grep -vE '^[[:space:]]*#' "$RUNNER" | grep -qF -- '-e "$name=${!name}"'; then
  fail 'runner.sh passthrough embeds values in docker argv (must be bare -e "$name")'
else
  pass "runner.sh passthrough forwards variable names only"
fi

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]]
