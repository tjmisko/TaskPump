#!/bin/bash
# entrypoint-parallel.sh -- firewall -> smoke test -> drop to dev user ->
# run ONE long Auto Mode session against an assigned kickoff brief.
#
# This is the parallel-fan-out successor to entrypoint.sh's ralph loop.
# Differences:
#   * No iteration loop, no `arachne-task next`, no scrub. Each container is
#     pre-assigned exactly one worktree + brief by run-parallel.sh, so there
#     is no shared-queue claim race between concurrent agents.
#   * Permission posture is Auto Mode (--permission-mode auto), NOT
#     --dangerously-skip-permissions. The iptables egress allowlist remains
#     the hard sandbox; the classifier is the second layer.
#   * The agent claims/completes its OWN F4x task(s) (the brief instructs it);
#     this entrypoint only claims the epic task as a safety net and never
#     auto-completes (done = green build + tests + PR, which the agent asserts).
#
# Required env (set by run-parallel.sh):
#   WORKSPACE_PATH   -- the worktree path (container workdir)
#   REPO_ROOT        -- main checkout root; canonical ops/ lives here
#   ARACHNE_BRIEF    -- path to the kickoff brief .md (the agent's prompt)
#   ARACHNE_TASK_ID  -- epic/top task ID for this worktree (e.g. F41.3)
# Optional env:
#   GITHUB_TOKEN        -- for ops/ submodule fetch + gh
#   MAX_TURNS           -- max turns for the single session (default 600)
#   AGENT_MODEL         -- model alias (default opus)
#   ARACHNE_RESUME_NOTE -- path to a resume preamble (run-parallel.sh --resume);
#                          prepended to the brief on stdin when present.
set -euo pipefail

: "${WORKSPACE_PATH:=/workspace}"
[[ -d "$WORKSPACE_PATH" ]] || { echo "ERROR: WORKSPACE_PATH=$WORKSPACE_PATH missing" >&2; exit 1; }
cd "$WORKSPACE_PATH"

: "${REPO_ROOT:=$WORKSPACE_PATH}"
OPS_DIR="$REPO_ROOT/ops"

LOG_FILE="$WORKSPACE_PATH/.arachne-agent.log"
echo "Arachne parallel agent started at $(date -u) (workspace: $WORKSPACE_PATH)" | tee "$LOG_FILE"

# ── Firewall (identical allowlist to the serial entrypoint) ────────────────────
echo "Configuring firewall..." | tee -a "$LOG_FILE"
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -d api.anthropic.com -j ACCEPT
iptables -A OUTPUT -d registry.npmjs.org -j ACCEPT
iptables -A OUTPUT -d registry.yarnpkg.com -j ACCEPT
# GitHub CIDR ranges (see entrypoint.sh comment; refresh from api.github.com/meta)
iptables -A OUTPUT -d 140.82.112.0/20 -j ACCEPT
iptables -A OUTPUT -d 143.55.64.0/20  -j ACCEPT
iptables -A OUTPUT -d 192.30.252.0/22 -j ACCEPT
iptables -A OUTPUT -d 185.199.108.0/22 -j ACCEPT
iptables -A OUTPUT -d 20.201.28.0/22  -j ACCEPT
iptables -A OUTPUT -d 20.205.243.0/24 -j ACCEPT
iptables -A OUTPUT -d 20.207.73.0/24  -j ACCEPT
iptables -A OUTPUT -d 20.233.83.0/24  -j ACCEPT
iptables -A OUTPUT -d 20.248.137.0/24 -j ACCEPT
iptables -A OUTPUT -d crates.io -j ACCEPT
iptables -A OUTPUT -d static.crates.io -j ACCEPT
iptables -A OUTPUT -d index.crates.io -j ACCEPT
iptables -A OUTPUT -d mcp.context7.com -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -j DROP
echo "Firewall configured" | tee -a "$LOG_FILE"

# ── Credential refresher (RC-1 fix, F65.1 / A2) ────────────────────────────────
# The host ~/.claude is bind-mounted READ-ONLY at /tmp/claude-home, so
# /tmp/claude-home/.credentials.json always reflects the LIVE host token (the
# host's Claude Code auth daemon rewrites it in place). But the per-container copy
# at /home/dev/.claude/.credentials.json is a frozen snapshot taken once at
# startup — once that access token's TTL (~6h, observed 2026-06-23) elapses every
# API call 401s and the session dies. refresh_credentials() re-copies the live
# token (and .claude.json) into the dev home with a JSON-validity guard and an
# atomic temp-file swap, so a long-running container tracks host refreshes.
#
# SPEC_GAP: it is unknown (and undocumented) whether `claude -p` re-reads
# .credentials.json per API request (Case A) or caches the token in memory at
# startup (Case B). This is designed for BOTH: under Case A the periodic re-copy
# rescues the in-flight session as soon as a fresh token lands; under Case B the
# re-copy cannot rescue an already-started session, but it still leaves a valid
# token for the NEXT container (the pump's A1 liveness-reclaim relaunches dead
# containers) and the optional AGENT_WALL_TIMEOUT_S backstop bounds the damage
# window. The refresh can never do worse than today's single-copy behavior. A
# live run crossing a real host token refresh is the only proof of which case
# holds — see the F64 canary runbook.
refresh_credentials() {
    local src="/tmp/claude-home/.credentials.json"
    local dst="/home/dev/.claude/.credentials.json"
    local tmp="${dst}.tmp.$$"

    # .credentials.json — copy to temp, validate, atomic-swap. On any failure
    # leave the previous (stale-but-valid) copy in place and retry next tick.
    if [[ -f "$src" ]]; then
        if cp "$src" "$tmp" 2>/dev/null && jq -e '.claudeAiOauth.accessToken' "$tmp" >/dev/null 2>&1; then
            mv "$tmp" "$dst"
            chown dev:dev "$dst" 2>/dev/null || true
            chmod u+rw "$dst" 2>/dev/null || true
            echo "$(date -u) [cred-refresh] .credentials.json refreshed" >> "$LOG_FILE"
        else
            echo "$(date -u) [cred-refresh] WARNING: .credentials.json invalid after copy; keeping previous" >> "$LOG_FILE"
            rm -f "$tmp"
            return 1
        fi
    fi

    # .claude.json — same validated atomic-swap pattern as the startup copy.
    local src_cj="/tmp/claude-home-json/.claude.json"
    local dst_cj="/home/dev/.claude.json"
    local tmp_cj="${dst_cj}.tmp.$$"
    if [[ -f "$src_cj" ]]; then
        if cp "$src_cj" "$tmp_cj" 2>/dev/null && jq -e . "$tmp_cj" >/dev/null 2>&1; then
            mv "$tmp_cj" "$dst_cj"
            chown dev:dev "$dst_cj" 2>/dev/null || true
            chmod u+rw "$dst_cj" 2>/dev/null || true
        else
            echo "$(date -u) [cred-refresh] WARNING: .claude.json invalid after copy; keeping previous" >> "$LOG_FILE"
            rm -f "$tmp_cj"
        fi
    fi
    return 0
}

# ── Configure dev user's Claude home + Auto Mode settings ──────────────────────
mkdir -p /home/dev/.claude
if [[ -d /tmp/claude-home ]]; then
    cp -a /tmp/claude-home/. /home/dev/.claude/
fi
# Merge MCP config + Auto Mode settings into one settings.json so MCP servers
# and the auto permission mode + allow rules coexist. Auto settings win on
# conflicting keys. These live with the orchestrator in the primary checkout
# (REPO_ROOT), NOT in the worktree, so connector worktrees stay pure-from-main.
MCP_JSON="$REPO_ROOT/claude-mcp.json"
AUTO_JSON="$REPO_ROOT/claude-settings-auto.json"
if [[ -f "$MCP_JSON" && -f "$AUTO_JSON" ]]; then
    jq -s '.[0] * .[1]' "$MCP_JSON" "$AUTO_JSON" > /home/dev/.claude/settings.json
elif [[ -f "$AUTO_JSON" ]]; then
    cp "$AUTO_JSON" /home/dev/.claude/settings.json
elif [[ -f "$MCP_JSON" ]]; then
    cp "$MCP_JSON" /home/dev/.claude/settings.json
fi
if [[ -f /tmp/claude-home-json/.claude.json ]]; then
    # Validated copy with retry. The host file is actively written by the
    # user's primary claude session (telemetry, recently-used, etc.), so a
    # naive cp can capture a mid-write torn state — observed 2026-05-28 when
    # a parallel cohort silently died on `Unexpected EOF` parsing the
    # corrupted /home/dev/.claude.json. Retry the copy a few times against
    # `jq -e .` (≈ "parses as valid JSON"); if every attempt loses the race,
    # bail BEFORE arachne-task heartbeat --start so the failure doesn't
    # consume an iteration on the task tripwire counter.
    attempt=0; max_attempts=6; sleep_s=2
    while (( attempt < max_attempts )); do
        cp /tmp/claude-home-json/.claude.json /home/dev/.claude.json
        if jq -e . /home/dev/.claude.json >/dev/null 2>&1; then
            break
        fi
        attempt=$((attempt + 1))
        echo "WARNING: /home/dev/.claude.json invalid after copy (attempt $attempt/$max_attempts); retrying in ${sleep_s}s" | tee -a "$LOG_FILE"
        sleep "$sleep_s"
    done
    if ! jq -e . /home/dev/.claude.json >/dev/null 2>&1; then
        echo "ERROR: failed to obtain a valid /home/dev/.claude.json after $max_attempts attempts (host file may be in flux). Exiting before the task heartbeat starts so no failed-iteration is recorded." | tee -a "$LOG_FILE"
        exit 75  # EX_TEMPFAIL — operator-recoverable
    fi
fi
chown -R dev:dev /home/dev/.claude /home/dev/.claude.json 2>/dev/null || true
chmod -R u+rw /home/dev/.claude 2>/dev/null || true
chmod u+rw /home/dev/.claude.json 2>/dev/null || true
echo "Credentials + Auto Mode settings configured" | tee -a "$LOG_FILE"
echo "permission mode: $(jq -r '.permissions.defaultMode // "default"' /home/dev/.claude/settings.json 2>/dev/null)" | tee -a "$LOG_FILE"

# ── Background credential refresher (RC-1 fix, F65.1 / A2) ──────────────────────
# Periodically re-copies .credentials.json (and .claude.json) from the live
# read-only mount so a long-running container tracks host token refreshes and
# does not 401 once the startup token's TTL elapses. Runs as root in a child
# subshell; the container teardown on exit (or `exec su dev` below) reaps it —
# no explicit cleanup needed. A failed tick (`|| true`) never kills the loop.
CRED_REFRESH_INTERVAL_S="${CRED_REFRESH_INTERVAL_S:-300}"
(
    while true; do
        sleep "$CRED_REFRESH_INTERVAL_S"
        refresh_credentials || true
    done
) &
CRED_REFRESH_PID=$!
echo "Credential refresher started (interval=${CRED_REFRESH_INTERVAL_S}s, pid=$CRED_REFRESH_PID)" | tee -a "$LOG_FILE"

# ── Git HTTPS auth ─────────────────────────────────────────────────────────────
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    su dev -c "git config --global url.'https://x-access-token:${GITHUB_TOKEN}@github.com/'.insteadOf 'https://github.com/'"
    echo "Git HTTPS auth configured" | tee -a "$LOG_FILE"
else
    echo "WARNING: GITHUB_TOKEN not set; ops/ fetch + gh pr will fail" | tee -a "$LOG_FILE"
fi

# ── Smoke test ─────────────────────────────────────────────────────────────────
echo "Running smoke test..." | tee -a "$LOG_FILE"
WORKSPACE_PATH="$WORKSPACE_PATH" /smoke_test.sh 2>&1 | tee -a "$LOG_FILE" || echo "WARNING: Smoke test had failures (continuing)" | tee -a "$LOG_FILE"

# ── Resolve the kickoff brief (the agent's prompt) ─────────────────────────────
: "${ARACHNE_BRIEF:=}"
if [[ -z "$ARACHNE_BRIEF" ]]; then
    echo "ERROR: ARACHNE_BRIEF not set; parallel mode requires an assigned brief" | tee -a "$LOG_FILE" >&2
    exit 1
fi
# Allow brief paths relative to the canonical ops/ or the repo root.
if [[ ! -f "$ARACHNE_BRIEF" ]]; then
    for cand in "$OPS_DIR/$ARACHNE_BRIEF" "$REPO_ROOT/$ARACHNE_BRIEF" "$WORKSPACE_PATH/$ARACHNE_BRIEF"; do
        [[ -f "$cand" ]] && ARACHNE_BRIEF="$cand" && break
    done
fi
[[ -f "$ARACHNE_BRIEF" ]] || { echo "ERROR: brief not found: $ARACHNE_BRIEF" | tee -a "$LOG_FILE" >&2; exit 1; }
echo "Brief: $ARACHNE_BRIEF" | tee -a "$LOG_FILE"

# Optional resume preamble. Bind-mounted at the same absolute path as the host,
# so the env value resolves directly; fall back to the conventional location.
: "${ARACHNE_RESUME_NOTE:=}"
if [[ -n "$ARACHNE_RESUME_NOTE" && ! -f "$ARACHNE_RESUME_NOTE" && -f "$WORKSPACE_PATH/.arachne-resume.md" ]]; then
    ARACHNE_RESUME_NOTE="$WORKSPACE_PATH/.arachne-resume.md"
fi
if [[ -n "$ARACHNE_RESUME_NOTE" && -f "$ARACHNE_RESUME_NOTE" ]]; then
    echo "Resume preamble: $ARACHNE_RESUME_NOTE (prepended to brief)" | tee -a "$LOG_FILE"
else
    ARACHNE_RESUME_NOTE=""
fi

# ── Goal preamble ──────────────────────────────────────────────────────────────
# Every task handed to an agent gets a clear goal up front. Read the epic's
# one-line goal from its task file (canonical ops/) and write a small preamble
# that is prepended to the brief on stdin ahead of any resume note — mirroring
# the resume-preamble mechanism, so the hand-authored briefs stay pure.
GOAL_NOTE=""
if [[ -n "${ARACHNE_TASK_ID:-}" ]]; then
    GOAL_TEXT="$(yq --front-matter=extract '.goal' "$OPS_DIR/task-loop/tasks/${ARACHNE_TASK_ID}.md" 2>/dev/null || echo '')"
    [[ "$GOAL_TEXT" == "null" ]] && GOAL_TEXT=""
    if [[ -n "$GOAL_TEXT" ]]; then
        GOAL_NOTE="$WORKSPACE_PATH/.arachne-goal.md"
        {
            echo "# GOAL — the outcome this session must achieve"
            echo
            echo "$GOAL_TEXT"
            echo
            echo "Everything below (resume context, kickoff brief) serves this goal. If the"
            echo "brief's steps and this goal ever appear to conflict, the goal wins — surface"
            echo "the conflict rather than silently following either."
            echo
            echo "---"
            echo
        } > "$GOAL_NOTE"
        chmod 666 "$GOAL_NOTE" 2>/dev/null || true
        echo "Goal: $GOAL_TEXT" | tee -a "$LOG_FILE"
    else
        echo "WARNING: epic ${ARACHNE_TASK_ID} has no goal — set one with 'arachne-task goal ${ARACHNE_TASK_ID} --set \"...\"'" | tee -a "$LOG_FILE"
    fi
fi

chmod 666 "$LOG_FILE"
chown -R dev:dev "$WORKSPACE_PATH/.arachne-agent.log" 2>/dev/null || true

MAX_TURNS="${MAX_TURNS:-600}"
AGENT_MODEL="${AGENT_MODEL:-opus}"
TASK_ID="${ARACHNE_TASK_ID:-}"

echo | tee -a "$LOG_FILE"
echo "Starting single Auto Mode session" | tee -a "$LOG_FILE"
echo "  Workspace: $WORKSPACE_PATH" | tee -a "$LOG_FILE"
echo "  Task:      ${TASK_ID:-<none>}" | tee -a "$LOG_FILE"
echo "  Model:     $AGENT_MODEL    Max turns: $MAX_TURNS" | tee -a "$LOG_FILE"
echo | tee -a "$LOG_FILE"

# The single dev-user session script. Captured in a variable so it can be run
# either with `exec` (default) or wrapped in `timeout` (when a wall-clock cap is
# set) without duplicating the body. Host-side vars are expanded here at
# assignment; `\$...` stay literal for the dev shell to expand at run time.
DEV_SESSION_SCRIPT="
    cd '$WORKSPACE_PATH'
    export PATH=/usr/local/cargo/bin:\$PATH
    export GITHUB_TOKEN='${GITHUB_TOKEN:-}'
    export CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1
    export DISABLE_TELEMETRY=1
    export DISABLE_ERROR_REPORTING=1

    # All arachne-task ops target the canonical ops/ in the main repo; code
    # productivity is measured against the worktree (this branch).
    export ARACHNE_TASKS_DIR='$OPS_DIR/task-loop/tasks'
    export ARACHNE_TASK_OUT='$OPS_DIR/task-loop/.next-task'
    export ARACHNE_CODE_REPO='$WORKSPACE_PATH'
    export ARACHNE_TASK_PUSH=1

    CURRENT_BRANCH=\$(git -C '$WORKSPACE_PATH' branch --show-current)
    echo \"Branch: \$CURRENT_BRANCH\" | tee -a '$LOG_FILE'

    # Safety-net claim of the epic task (the agent re-claims/sub-claims as the
    # brief directs). Harmless if already claimed by this branch (idempotent).
    if [ -n '$TASK_ID' ]; then
        '$WORKSPACE_PATH/scripts/arachne-task' claim '$TASK_ID' --branch \"\$CURRENT_BRANCH\" --turns 9999 2>&1 | tee -a '$LOG_FILE' || true
        '$WORKSPACE_PATH/scripts/arachne-task' heartbeat '$TASK_ID' --start 2>&1 | tee -a '$LOG_FILE' || true
    fi

    # ── The single long session ──────────────────────────────────────────────
    # --permission-mode auto: server-side classifier gates dangerous actions;
    # no --dangerously-skip-permissions. In headless -p, the session aborts
    # after repeated classifier blocks; we treat that as park-for-review.
    # Stdin order: goal preamble, then resume preamble (if any), then the brief.
    PROMPT_PARTS=''
    [ -n '$GOAL_NOTE' ] && [ -f '$GOAL_NOTE' ] && PROMPT_PARTS=\"\$PROMPT_PARTS$GOAL_NOTE \"
    [ -n '$ARACHNE_RESUME_NOTE' ] && [ -f '$ARACHNE_RESUME_NOTE' ] && PROMPT_PARTS=\"\$PROMPT_PARTS$ARACHNE_RESUME_NOTE \"
    cat \$PROMPT_PARTS '$ARACHNE_BRIEF' | claude -p \
        --permission-mode auto \
        --model '$AGENT_MODEL' \
        --verbose \
        --output-format stream-json \
        --max-turns $MAX_TURNS \
        2>&1 | tee -a '$LOG_FILE'
    SESSION_RC=\$?
    echo \"Session exited (rc=\$SESSION_RC)\" | tee -a '$LOG_FILE'

    # End heartbeat only if the agent left the epic in_progress (i.e. didn't
    # call complete/block itself). Never auto-complete: 'done' requires the
    # agent to have asserted green build + tests + PR via arachne-task complete.
    if [ -n '$TASK_ID' ]; then
        TASK_FILE='$OPS_DIR/task-loop/tasks/$TASK_ID.md'
        TASK_STATUS=\$(yq --front-matter=extract '.status' \"\$TASK_FILE\" 2>/dev/null || echo '')
        if [ \"\$TASK_STATUS\" = 'in_progress' ]; then
            '$WORKSPACE_PATH/scripts/arachne-task' heartbeat '$TASK_ID' --end 2>&1 | tee -a '$LOG_FILE' || true
            echo \"Epic $TASK_ID left in_progress — parked for review.\" | tee -a '$LOG_FILE'
        else
            echo \"Epic $TASK_ID final status: \$TASK_STATUS\" | tee -a '$LOG_FILE'
        fi
    fi

    # Push canonical ops/ so the host + monitor see final state.
    (cd '$OPS_DIR' && git push 2>&1) | tee -a '$LOG_FILE' || true
    echo \"Parallel agent finished at \$(date -u).\" | tee -a '$LOG_FILE'
"

# ── Launch the session: optional wall-clock backstop, else exec ────────────────
# AGENT_WALL_TIMEOUT_S (opt-in; unset = backward-compatible exec path) caps the
# session wall-clock as a last-resort guard below the token TTL. `timeout` needs
# a child to signal, so we cannot `exec` in that branch — a desirable side
# effect is that the end-heartbeat + ops-push inside the script run on a
# wall-clock kill, whereas `exec` silently drops them when the process is
# replaced. `|| WALL_RC=$?` keeps `set -e` from aborting before we capture rc.
if [[ -n "${AGENT_WALL_TIMEOUT_S:-}" ]]; then
    echo "Wall-clock cap: ${AGENT_WALL_TIMEOUT_S}s" | tee -a "$LOG_FILE"
    WALL_RC=0
    timeout "$AGENT_WALL_TIMEOUT_S" su dev -c "$DEV_SESSION_SCRIPT" || WALL_RC=$?
    if [[ "$WALL_RC" -eq 124 ]]; then
        echo "$(date -u) [wall-cap] session killed by wall-clock timeout (${AGENT_WALL_TIMEOUT_S}s)" | tee -a "$LOG_FILE"
    fi
    exit "$WALL_RC"
else
    exec su dev -c "$DEV_SESSION_SCRIPT"
fi
