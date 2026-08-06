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

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

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
TASKPUMP_SAFETY_TURNS TASKPUMP_WORKSPACE_TASK_CLI
TASKPUMP_CONTAINER_USER TASKPUMP_CONTAINER_HOME
TASKPUMP_PRE_FLIGHT TP_PRE_FLIGHT
TASKPUMP_AGENT_LOG_NAME TASKPUMP_GOAL_NOTE_NAME
TASKPUMP_RESUME_NOTE_NAME TASKPUMP_RO_PROBE_FILE
TASKPUMP_HOST_CRED_MOUNT TASKPUMP_HOST_CONFIG_MOUNT
TASKPUMP_CRED_REFRESH_INTERVAL_S CRED_REFRESH_INTERVAL_S
TASKPUMP_AGENT_WALL_TIMEOUT_S AGENT_WALL_TIMEOUT_S
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
if grep -qF 'cp "$AUTO_JSON" /home/dev/.claude/settings.json' "$PF" \
   && grep -qF 'cp "$MCP_JSON" /home/dev/.claude/settings.json' "$PF"; then
  pass "pre-flight falls back to whichever config exists when only one is present"
else
  fail "preflight-example.sh is missing a single-sided fallback for MCP-only / Auto-only"
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
n=$(grep -cE "^\s+'\\\$TASK_CLI'" "$EP")
[[ "$n" -eq 3 ]] && pass "all three task-CLI call sites go through \$TASK_CLI (claim, --start, --end)" \
  || fail "expected 3 \$TASK_CLI call sites, found $n"

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
R1=$(mk_ws canon)
out_canon=$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TP_WORKSPACE="$R1/wt" TP_REPO_ROOT="$R1" TP_BRIEF="$R1/brief.md" \
  TP_TASK_ID=F9.1 TP_PHASE=F9 TP_MODEL=haiku TP_MAX_TURNS=42 \
  TASKPUMP_TASKS_DIR="$R1/tasks")
rc_canon=$?
out_legacy=$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  WORKSPACE_PATH="$R1/wt" REPO_ROOT="$R1" ARACHNE_BRIEF="$R1/brief.md" \
  ARACHNE_TASK_ID=F9.1 ARACHNE_PHASE=F9 AGENT_MODEL=haiku MAX_TURNS=42 \
  ARACHNE_TASKS_DIR="$R1/tasks")
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
grep -q "^task_cli=$R2/wt/scripts/arachne-task$" <<<"$rep_def" \
  && pass "workspace task CLI defaults to scripts/arachne-task under the workspace" \
  || fail "task CLI default wrong:\n$rep_def"

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

echo "--- stdin assembly ordering ---"
R3=$(mk_ws ordering)
printf 'resume preamble\n' >| "$R3/wt/.arachne-resume.md"
rep_ord=$(report "$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TP_WORKSPACE="$R3/wt" TP_REPO_ROOT="$R3" TP_BRIEF="$R3/brief.md" \
  TP_RESUME_NOTE="$R3/wt/.arachne-resume.md" \
  TP_TASK_ID=F9.1 TASKPUMP_TASKS_DIR="$R3/tasks")")
grep -q "prompt_parts=$R3/wt/.arachne-goal.md $R3/wt/.arachne-resume.md $R3/brief.md" <<<"$rep_ord" \
  && pass "stdin order is goal, then resume note, then brief" \
  || fail "stdin assembly order wrong:\n$rep_ord"
# The resume note is also findable by convention when the env path does not
# resolve inside the container.
rep_conv=$(report "$(run_ep TASKPUMP_ENTRYPOINT_TEST_MODE=plan \
  TP_WORKSPACE="$R3/wt" TP_REPO_ROOT="$R3" TP_BRIEF="$R3/brief.md" \
  TP_RESUME_NOTE=/host/only/path/.arachne-resume.md)")
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
got_norm=${got//$R6/@R@}
want='run --rm -d --name tp-agent-feat-f9 --cap-add NET_ADMIN --memory 3g --memory-swap 5g'
want+=' -e GITHUB_TOKEN= -e WORKSPACE_PATH=@R@/wt -e REPO_ROOT=@R@'
want+=' -e ARACHNE_BRIEF=@R@/brief.md -e ARACHNE_RESUME_NOTE= -e ARACHNE_TASK_ID=F9.1'
want+=' -e ARACHNE_PHASE=F9 -e MAX_TURNS=600 -e AGENT_MODEL=opus'
want+=' -e TASKPUMP_WORKSPACE_PATH=@R@/wt -e TASKPUMP_REPO_ROOT=@R@ -e TASKPUMP_LEDGER_REPO=@R@/ops'
want+=' -e TASKPUMP_BRIEF=@R@/brief.md -e TASKPUMP_RESUME_NOTE= -e TASKPUMP_TASK_ID=F9.1'
want+=' -e TASKPUMP_PHASE=F9 -e TASKPUMP_BRANCH=feat/f9 -e TASKPUMP_MAX_TURNS=600'
want+=' -e TASKPUMP_AGENT_MODEL=opus'
want+=' -v @R@/claude-home:/tmp/claude-home:ro'
want+=' -v @R@/claude.json:/tmp/claude-home-json/.claude.json:ro'
want+=' -v @R@:@R@:ro -v @R@/.git:@R@/.git -v @R@/wt:@R@/wt -v @R@/ops:@R@/ops'
want+=' -w @R@/wt agentimg /entrypoint-parallel.sh'
[[ $rc -eq 0 ]] && pass "launch exits 0 and prints the container id" || fail "launch rc=$rc:\n$got"
if [[ "$got_norm" == "$want" ]]; then
  pass "launch reproduces the golden docker run line exactly"
else
  fail "launch line drifted.\n--- want ---\n$want\n--- got ---\n$got_norm"
fi

# The individual invariants the golden line encodes, asserted separately so a
# failure says which one broke rather than just "the line changed".
for probe in \
  '--cap-add NET_ADMIN' '--memory 3g' '--memory-swap 5g' '--rm -d' \
  "-v @R@:@R@:ro" "-v @R@/.git:@R@/.git" "-v @R@/wt:@R@/wt" "-v @R@/ops:@R@/ops"; do
  grep -qF -- "$probe" <<<"$got_norm" && pass "launch line carries '$probe'" \
    || fail "launch line is missing '$probe'"
done
# The read-only primary must not have regressed to a blanket RW mount.
if grep -qE -- "-v @R@:@R@( |$)" <<<"$got_norm"; then
  fail "blanket RW primary mount re-introduced (the read-only mount regressed)"
else
  pass "no blanket RW primary mount"
fi

got=$(launch_line TP_ENTRYPOINT=/tp-entrypoint.sh TP_IMAGE=other TP_MEMORY_MAX=8g)
got_norm=${got//$R6/@R@}
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
grep -qF -- '-e TASKPUMP_PRE_FLIGHT=/preflight.sh' <<<"$got" \
  && pass "a set passthrough variable is forwarded into the container" \
  || fail "passthrough did not forward TASKPUMP_PRE_FLIGHT:\n$got"

# Legacy-only inputs must produce the same line as canonical-only inputs.
got_legacy=$(run_runner launch DOCKER=/bin/echo \
  WORKSPACE_PATH="$R6/wt" REPO_ROOT="$R6" \
  ARACHNE_CONTAINER_NAME=tp-agent-feat-f9 ARACHNE_IMAGE=agentimg \
  ARACHNE_BRANCH=feat/f9 ARACHNE_TASK_ID=F9.1 ARACHNE_PHASE=F9 \
  ARACHNE_BRIEF="$R6/brief.md" AGENT_MODEL=opus MAX_TURNS=600 \
  CLAUDE_DIR="$R6/claude-home" CLAUDE_JSON="$R6/claude.json")
[[ "${got_legacy//$R6/@R@}" == "$want" ]] \
  && pass "legacy-only runner inputs produce the identical launch line" \
  || fail "legacy runner inputs diverged:\n${got_legacy//$R6/@R@}"

echo "--- runner.sh error + stop contract ---"
out=$(run_runner launch DOCKER=/bin/echo TP_WORKSPACE="$R6/wt" TP_REPO_ROOT="$R6" \
  TP_CONTAINER_NAME=c1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'TP_IMAGE is required' <<<"$out" \
  && pass "a missing TP_IMAGE fails loudly rather than defaulting" || fail "missing image not rejected:\n$out"
out=$(run_runner launch DOCKER=/bin/echo TP_REPO_ROOT="$R6" TP_CONTAINER_NAME=c1 TP_IMAGE=i); rc=$?
[[ $rc -ne 0 ]] && grep -q 'TP_WORKSPACE' <<<"$out" \
  && pass "a missing workspace fails loudly" || fail "missing workspace not rejected:\n$out"

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

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]]
