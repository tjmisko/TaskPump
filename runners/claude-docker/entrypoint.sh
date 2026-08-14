#!/bin/bash
# runners/claude-docker/entrypoint.sh — the generic in-container half of the
# claude-docker runner. Baked into the agent image; started by runner.sh.
#
# One container runs ONE long agent session against one assigned workspace and
# one assigned brief. There is no iteration loop and no queue read here: the
# supervisor decided what this container is for before it existed, so there is
# no claim race between concurrent agents.
#
# What this file owns is everything that is true of *any* consumer:
#
#   * the environment contract (canonical TASKPUMP_*/TP_* names, legacy
#     ARACHNE_* fallbacks) — see the table below;
#   * the access-token-only credential install, which is a hardening lesson
#     rather than a preference (see install_access_only_credentials);
#   * stdin assembly for the session: goal, then resume note, then brief;
#   * the safety-net claim + heartbeat discipline around the session;
#   * exit-code discipline, in particular exit 75 before `heartbeat --start`.
#
# What it does NOT own is anything that knows the shape of a particular repo:
# the egress allowlist, the toolchain, the smoke test, the agent's settings
# files. Those go in a pre-flight hook — see TASKPUMP_PRE_FLIGHT below and
# preflight-example.sh next door.
#
# ── Environment contract ──────────────────────────────────────────────────────
#
# Each row is read canonical-first: TASKPUMP_<NAME>, then TP_<NAME>, then the
# legacy spelling, then the default. Both spellings are supplied by runner.sh.
#
#   canonical                        legacy               default
#   TASKPUMP_WORKSPACE_PATH          WORKSPACE_PATH       /workspace
#   TASKPUMP_REPO_ROOT               REPO_ROOT            $WORKSPACE_PATH
#   TASKPUMP_LEDGER_REPO             —                    $REPO_ROOT/ops
#   TASKPUMP_TASKS_DIR               ARACHNE_TASKS_DIR    $LEDGER_REPO/tasks
#   TASKPUMP_TASK_OUT                ARACHNE_TASK_OUT     $LEDGER_REPO/.next-task
#   TASKPUMP_TASK_FILE_EXT           —                    .md
#   TASKPUMP_BRIEF                   ARACHNE_BRIEF        (required)
#   TASKPUMP_RESUME_NOTE             ARACHNE_RESUME_NOTE  (none)
#   TASKPUMP_TASK_ID                 ARACHNE_TASK_ID      (none)
#   TASKPUMP_PHASE                   ARACHNE_PHASE        (none)
#   TASKPUMP_MAX_TURNS               MAX_TURNS            600
#   TASKPUMP_AGENT_MODEL             AGENT_MODEL          opus
#   TASKPUMP_SAFETY_TURNS            —                    3
#   TASKPUMP_WORKSPACE_TASK_CLI      —                    tp (on PATH; startup fails
#                                                         loudly when it is absent)
#   TASKPUMP_CONTAINER_USER          —                    dev
#   TASKPUMP_CONTAINER_HOME          —                    /home/$CONTAINER_USER
#   TASKPUMP_PRE_FLIGHT              —                    (none; see below)
#   TASKPUMP_AGENT_LOG_NAME          —                    .taskpump-agent.log
#   TASKPUMP_GOAL_NOTE_NAME          —                    .taskpump-goal.md
#   TASKPUMP_RESUME_NOTE_NAME        —                    .taskpump-resume.md
#   TASKPUMP_RO_PROBE_FILE           —                    .taskpump-rotest
#   TASKPUMP_HOST_CRED_MOUNT         —                    /tmp/claude-home
#   TASKPUMP_HOST_CONFIG_MOUNT       —                    /tmp/claude-home-json/.claude.json
#   TASKPUMP_CRED_REFRESH_INTERVAL_S CRED_REFRESH_INTERVAL_S  300
#   TASKPUMP_AGENT_WALL_TIMEOUT_S    AGENT_WALL_TIMEOUT_S (unset)
#   GITHUB_TOKEN                     —                    (unset)
#
# The agent-log NAME is load-bearing: the monitor and the cleanup sweeper find a
# running agent by looking for `<worktree>/$TASKPUMP_AGENT_LOG_NAME`, so every
# tool in a run must resolve the same name. Changing the default (or the key)
# under a LIVE drain makes running agents invisible to the tools that supervise
# them — an operator keeping the historical names pins them in taskpump.conf
# (see examples/arachne.conf).
#
# ── The pre-flight hook ───────────────────────────────────────────────────────
#
# TASKPUMP_PRE_FLIGHT names an executable *inside the container*. It runs as
# root after credentials are installed and before the session starts, with
# WORKSPACE_PATH / REPO_ROOT / LEDGER_REPO / LOG_FILE / TASKPUMP_CONTAINER_USER /
# TASKPUMP_CONTAINER_HOME / TASKPUMP_TASK_ID / TASKPUMP_PHASE exported. A
# non-zero exit aborts with 75 (EX_TEMPFAIL), before the heartbeat starts.
#
# Unset means no pre-flight — EXCEPT for one transitional fallback. A container
# built before the hook existed has no TASKPUMP_PRE_FLIGHT to set, so if the
# variable is unset AND the legacy marker file (claude-settings-auto.json, in
# either REPO_ROOT or WORKSPACE_PATH) is present, the old inline pre-flight runs
# instead. That keeps today's images working across the transition. It is
# scheduled for deletion once consumers set the hook; nothing new should rely on
# it, and a consumer that sets TASKPUMP_PRE_FLIGHT never reaches it.
#
# ── Exit codes ────────────────────────────────────────────────────────────────
#
#   0    session finished (whatever the agent concluded)
#   1    misconfiguration the operator must fix (no workspace, no brief)
#   75   EX_TEMPFAIL — retryable, raised BEFORE `heartbeat --start` so a failure
#        here never consumes an iteration on the task's tripwire counter
#   124  the optional wall-clock cap fired
set -euo pipefail

# ── Environment resolution ────────────────────────────────────────────────────

# ep_first <name>... — value of the first variable that is set and non-empty.
# Indirect expansion rather than eval: a value containing shell metacharacters,
# spaces, or newlines is never re-parsed.
ep_first() {
    local name
    for name in "$@"; do
        if [[ -n "${!name-}" ]]; then
            printf '%s' "${!name}"
            return 0
        fi
    done
    printf ''
}

WORKSPACE_PATH="$(ep_first TASKPUMP_WORKSPACE_PATH TP_WORKSPACE WORKSPACE_PATH)"
: "${WORKSPACE_PATH:=/workspace}"
[[ -d "$WORKSPACE_PATH" ]] || { echo "ERROR: WORKSPACE_PATH=$WORKSPACE_PATH missing" >&2; exit 1; }
cd "$WORKSPACE_PATH"

REPO_ROOT="$(ep_first TASKPUMP_REPO_ROOT TP_REPO_ROOT REPO_ROOT)"
: "${REPO_ROOT:=$WORKSPACE_PATH}"
LEDGER_REPO="$(ep_first TASKPUMP_LEDGER_REPO TP_LEDGER_REPO)"
: "${LEDGER_REPO:=$REPO_ROOT/ops}"

TASKS_DIR="$(ep_first TASKPUMP_TASKS_DIR TP_TASKS_DIR ARACHNE_TASKS_DIR)"
: "${TASKS_DIR:=$LEDGER_REPO/tasks}"
TASK_OUT="$(ep_first TASKPUMP_TASK_OUT TP_TASK_OUT ARACHNE_TASK_OUT)"
# Kept at dirname(TASKS_DIR)/.next-task, mirroring tp-task's own derivation.
: "${TASK_OUT:=$LEDGER_REPO/.next-task}"
TASK_FILE_EXT="$(ep_first TASKPUMP_TASK_EXT TASKPUMP_TASK_FILE_EXT TP_TASK_FILE_EXT)"
: "${TASK_FILE_EXT:=.md}"

BRIEF="$(ep_first TASKPUMP_BRIEF TP_BRIEF ARACHNE_BRIEF)"
RESUME_NOTE="$(ep_first TASKPUMP_RESUME_NOTE TP_RESUME_NOTE ARACHNE_RESUME_NOTE)"
TASK_ID="$(ep_first TASKPUMP_TASK_ID TP_TASK_ID ARACHNE_TASK_ID)"
PHASE="$(ep_first TASKPUMP_PHASE TP_PHASE ARACHNE_PHASE)"

MAX_TURNS="$(ep_first TASKPUMP_MAX_TURNS TP_MAX_TURNS MAX_TURNS)"
: "${MAX_TURNS:=600}"
AGENT_MODEL="$(ep_first TASKPUMP_AGENT_MODEL TP_MODEL AGENT_MODEL)"
: "${AGENT_MODEL:=opus}"
SAFETY_TURNS="$(ep_first TASKPUMP_SAFETY_TURNS TP_SAFETY_TURNS)"
: "${SAFETY_TURNS:=3}"

WORKSPACE_TASK_CLI="$(ep_first TASKPUMP_WORKSPACE_TASK_CLI TP_WORKSPACE_TASK_CLI)"
: "${WORKSPACE_TASK_CLI:=tp}"
TASK_CLI="$WORKSPACE_TASK_CLI"
case "$TASK_CLI" in
    /*) ;;                                      # absolute: used as given
    */*) TASK_CLI="$WORKSPACE_PATH/$TASK_CLI";; # relative path: under the workspace
    *)
        # A bare command name resolves on PATH inside the container. Until the
        # agent image actually carries tp (G4.3), a bare run must fail HERE —
        # at startup, before the session — rather than let the agent discover a
        # missing ledger CLI mid-session and burn the iteration on it. The
        # error names both fixes.
        if ! command -v "$TASK_CLI" >/dev/null 2>&1; then
            echo "ERROR: task CLI '$TASK_CLI' is not on PATH in this container." >&2
            echo "Fix one of: set TASKPUMP_WORKSPACE_TASK_CLI to the ledger CLI's path in the workspace, or provide 'tp' in the agent image." >&2
            exit 1
        fi
        ;;
esac

CONTAINER_USER="$(ep_first TASKPUMP_CONTAINER_USER TP_CONTAINER_USER)"
: "${CONTAINER_USER:=dev}"
CONTAINER_HOME="$(ep_first TASKPUMP_CONTAINER_HOME TP_CONTAINER_HOME)"
: "${CONTAINER_HOME:=/home/$CONTAINER_USER}"
AGENT_CLAUDE_DIR="$CONTAINER_HOME/.claude"
AGENT_CLAUDE_JSON="$CONTAINER_HOME/.claude.json"

PRE_FLIGHT="$(ep_first TASKPUMP_PRE_FLIGHT TP_PRE_FLIGHT)"

AGENT_LOG_NAME="$(ep_first TASKPUMP_AGENT_LOG_NAME TP_AGENT_LOG_NAME)"
: "${AGENT_LOG_NAME:=.taskpump-agent.log}"
GOAL_NOTE_NAME="$(ep_first TASKPUMP_GOAL_NOTE_NAME TP_GOAL_NOTE_NAME)"
: "${GOAL_NOTE_NAME:=.taskpump-goal.md}"
RESUME_NOTE_NAME="$(ep_first TASKPUMP_RESUME_NOTE_NAME TP_RESUME_NOTE_NAME)"
: "${RESUME_NOTE_NAME:=.taskpump-resume.md}"
RO_PROBE_FILE="$(ep_first TASKPUMP_RO_PROBE_FILE TP_RO_PROBE_FILE)"
: "${RO_PROBE_FILE:=.taskpump-rotest}"

HOST_CRED_MOUNT="$(ep_first TASKPUMP_HOST_CRED_MOUNT TP_HOST_CRED_MOUNT)"
: "${HOST_CRED_MOUNT:=/tmp/claude-home}"
HOST_CONFIG_MOUNT="$(ep_first TASKPUMP_HOST_CONFIG_MOUNT TP_HOST_CONFIG_MOUNT)"
: "${HOST_CONFIG_MOUNT:=/tmp/claude-home-json/.claude.json}"
CRED_REFRESH_INTERVAL_S="$(ep_first TASKPUMP_CRED_REFRESH_INTERVAL_S TP_CRED_REFRESH_INTERVAL_S CRED_REFRESH_INTERVAL_S)"
: "${CRED_REFRESH_INTERVAL_S:=300}"
AGENT_WALL_TIMEOUT_S="$(ep_first TASKPUMP_AGENT_WALL_TIMEOUT_S TP_AGENT_WALL_TIMEOUT_S AGENT_WALL_TIMEOUT_S)"

# Test seam. `plan` resolves the environment, assembles the prompt, reports, and
# exits without touching credentials, the firewall, or the session. `preflight`
# additionally installs credentials and runs the pre-flight hook, then stops
# short of the session. Neither is used in production; both exist so the harness
# can exercise this file's real logic instead of grepping it.
TEST_MODE="$(ep_first TASKPUMP_ENTRYPOINT_TEST_MODE)"

LOG_FILE="$WORKSPACE_PATH/$AGENT_LOG_NAME"
echo "TaskPump agent started at $(date -u) (workspace: $WORKSPACE_PATH)" | tee "$LOG_FILE"

log() { echo "$*" | tee -a "$LOG_FILE"; }

# ── Credential handler: ACCESS-TOKEN-ONLY (hardened 2026-06-24) ────────────────
# The host agent home is bind-mounted READ-ONLY, so its credentials file always
# reflects the LIVE host token (the host's auth daemon rewrites it in place). We
# copy it into the container user's home — but with the refreshToken STRIPPED.
#
# WHY strip it: the OAuth refresh token ROTATES on every refresh (a new one is
# issued and the old invalidated). If a container performed a refresh it could
# not write the new refresh token back across the READ-ONLY mount, so the host —
# and every other client sharing the token, including the operator's own
# interactive sessions — would be left holding a dead refresh token and be forced
# to log in again. (Reported 2026-06-24: host sessions logged out whenever the
# pump ran.) Removing the refresh token makes a container PHYSICALLY UNABLE to
# rotate it: the HOST owns rotation, and the container tracks it by re-copying
# the host's freshly-issued accessToken each tick.
#
# CONSEQUENCE: a container can no longer self-refresh, so it depends on the host
# keeping its token fresh (a live host session, or a host-side refresh). If the
# ~6h access-token TTL elapses with no host refresh, API calls 401 and the
# session dies — recoverable: the supervisor's liveness reclaim relaunches it
# with the next fresh token, and the supervisor's feed gate pauses LAUNCHING
# while the host token is stale so dead containers aren't churned.
#
# SPEC_GAP: whether the agent CLI re-reads its credentials file per request
# (Case A: the periodic re-copy rescues the in-flight session) or caches the
# token at startup (Case B: the re-copy only helps the NEXT container) is still
# unproven. The access-token-only model is correct under both; only the
# in-flight-rescue benefit depends on Case A.

# install_access_only_credentials <src> <dst> — write <dst> as an access-token-only
# copy of <src> (drop .claudeAiOauth.refreshToken) via a validated atomic swap.
# Requires the accessToken to survive the transform. Returns non-zero (leaving any
# previous <dst> intact) when the source is unreadable or the transform fails.
install_access_only_credentials() {
    local src="$1" dst="$2" tmp="${2}.tmp.$$"
    [[ -f "$src" ]] || return 0
    if jq 'del(.claudeAiOauth.refreshToken)' "$src" > "$tmp" 2>/dev/null \
       && jq -e '.claudeAiOauth.accessToken' "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$dst"
        chown "$CONTAINER_USER:$CONTAINER_USER" "$dst" 2>/dev/null || true
        chmod u+rw "$dst" 2>/dev/null || true
        return 0
    fi
    rm -f "$tmp"
    return 1
}

refresh_credentials() {
    # Credentials — re-copy the host's freshly-rotated accessToken with the
    # refreshToken stripped (see install_access_only_credentials). On any failure
    # leave the previous (stale-but-valid) copy in place and retry next tick.
    if install_access_only_credentials \
         "$HOST_CRED_MOUNT/.credentials.json" \
         "$AGENT_CLAUDE_DIR/.credentials.json"; then
        echo "$(date -u) [cred-refresh] credentials refreshed (access-token-only)" >> "$LOG_FILE"
    else
        echo "$(date -u) [cred-refresh] WARNING: credentials invalid after transform; keeping previous" >> "$LOG_FILE"
    fi

    # Agent config — config/telemetry only (no OAuth refresh token), copied whole
    # via the same validated atomic-swap pattern as the startup copy.
    local tmp_cj="${AGENT_CLAUDE_JSON}.tmp.$$"
    if [[ -f "$HOST_CONFIG_MOUNT" ]]; then
        if cp "$HOST_CONFIG_MOUNT" "$tmp_cj" 2>/dev/null && jq -e . "$tmp_cj" >/dev/null 2>&1; then
            mv "$tmp_cj" "$AGENT_CLAUDE_JSON"
            chown "$CONTAINER_USER:$CONTAINER_USER" "$AGENT_CLAUDE_JSON" 2>/dev/null || true
            chmod u+rw "$AGENT_CLAUDE_JSON" 2>/dev/null || true
        else
            echo "$(date -u) [cred-refresh] WARNING: agent config invalid after copy; keeping previous" >> "$LOG_FILE"
            rm -f "$tmp_cj"
        fi
    fi
    return 0
}

install_credentials() {
    mkdir -p "$AGENT_CLAUDE_DIR"
    if [[ -d "$HOST_CRED_MOUNT" ]]; then
        cp -a "$HOST_CRED_MOUNT"/. "$AGENT_CLAUDE_DIR"/
        # The blanket copy above brought the host's full credentials (with the
        # refreshToken). Immediately replace them with an access-token-only copy
        # so the container is non-rotating from t=0 — otherwise a refresh inside
        # the first CRED_REFRESH_INTERVAL_S window would rotate the host's shared
        # token and log the host out.
        install_access_only_credentials \
            "$HOST_CRED_MOUNT/.credentials.json" \
            "$AGENT_CLAUDE_DIR/.credentials.json" \
            || log "WARNING: could not strip refreshToken from startup credentials; refresher will retry"
    fi

    if [[ -f "$HOST_CONFIG_MOUNT" ]]; then
        # Validated copy with retry. The host file is actively written by the
        # operator's own session (telemetry, recently-used, etc.), so a naive cp
        # can capture a mid-write torn state — observed 2026-05-28 when a
        # parallel cohort silently died on `Unexpected EOF` parsing a corrupted
        # config. Retry a few times against `jq -e .` ("parses as valid JSON");
        # if every attempt loses the race, bail BEFORE the task heartbeat starts
        # so the failure doesn't consume an iteration on the tripwire counter.
        local attempt=0 max_attempts=6 sleep_s=2
        while (( attempt < max_attempts )); do
            cp "$HOST_CONFIG_MOUNT" "$AGENT_CLAUDE_JSON"
            if jq -e . "$AGENT_CLAUDE_JSON" >/dev/null 2>&1; then
                break
            fi
            attempt=$((attempt + 1))
            log "WARNING: $AGENT_CLAUDE_JSON invalid after copy (attempt $attempt/$max_attempts); retrying in ${sleep_s}s"
            sleep "$sleep_s"
        done
        if ! jq -e . "$AGENT_CLAUDE_JSON" >/dev/null 2>&1; then
            log "ERROR: failed to obtain a valid $AGENT_CLAUDE_JSON after $max_attempts attempts (host file may be in flux). Exiting before the task heartbeat starts so no failed-iteration is recorded."
            exit 75  # EX_TEMPFAIL — operator-recoverable
        fi
    fi
}

# ── Pre-flight ────────────────────────────────────────────────────────────────

# legacy_markers_present — true when this looks like a pre-hook consumer image.
legacy_markers_present() {
    [[ -f "$REPO_ROOT/claude-settings-auto.json" || -f "$WORKSPACE_PATH/claude-settings-auto.json" ]]
}

# determine_pre_flight — decide, without running anything, which pre-flight path
# applies. Separated from execution so the plan can be reported in test mode and
# logged before it runs.
PRE_FLIGHT_PLAN=""
determine_pre_flight() {
    if [[ -n "$PRE_FLIGHT" ]]; then
        PRE_FLIGHT_PLAN="hook:$PRE_FLIGHT"
        return 0
    fi
    if legacy_markers_present; then
        PRE_FLIGHT_PLAN="legacy-inline"
        return 0
    fi
    PRE_FLIGHT_PLAN="none"
}

# legacy_pre_flight — TRANSITIONAL. The pre-split inline pre-flight, kept so an
# image built before TASKPUMP_PRE_FLIGHT existed keeps working. The maintained
# copy of this logic is preflight-example.sh; this one is scheduled for deletion
# once consumers set the hook. Do not extend it.
legacy_pre_flight() {
    log "Configuring firewall..."
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
    iptables -A OUTPUT -d api.anthropic.com -j ACCEPT
    iptables -A OUTPUT -d registry.npmjs.org -j ACCEPT
    iptables -A OUTPUT -d registry.yarnpkg.com -j ACCEPT
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
    log "Firewall configured"

    local mcp_json="$REPO_ROOT/claude-mcp.json"
    local auto_json="$REPO_ROOT/claude-settings-auto.json"
    if [[ -f "$mcp_json" && -f "$auto_json" ]]; then
        jq -s '.[0] * .[1]' "$mcp_json" "$auto_json" > "$AGENT_CLAUDE_DIR/settings.json"
    elif [[ -f "$auto_json" ]]; then
        cp "$auto_json" "$AGENT_CLAUDE_DIR/settings.json"
    elif [[ -f "$mcp_json" ]]; then
        cp "$mcp_json" "$AGENT_CLAUDE_DIR/settings.json"
    fi

    log "Running smoke test..."
    if [[ -x /smoke_test.sh ]]; then
        WORKSPACE_PATH="$WORKSPACE_PATH" /smoke_test.sh 2>&1 | tee -a "$LOG_FILE" \
            || log "WARNING: Smoke test had failures (continuing)"
    fi
}

run_pre_flight() {
    case "$PRE_FLIGHT_PLAN" in
        hook:*)
            local hook="${PRE_FLIGHT_PLAN#hook:}"
            if [[ ! -x "$hook" ]]; then
                log "ERROR: TASKPUMP_PRE_FLIGHT is not an executable in this container: $hook"
                exit 75
            fi
            log "Pre-flight hook: $hook"
            export WORKSPACE_PATH REPO_ROOT LEDGER_REPO LOG_FILE
            export TASKPUMP_CONTAINER_USER="$CONTAINER_USER"
            export TASKPUMP_CONTAINER_HOME="$CONTAINER_HOME"
            export TASKPUMP_TASK_ID="$TASK_ID"
            export TASKPUMP_PHASE="$PHASE"
            local rc=0
            "$hook" || rc=$?
            if (( rc != 0 )); then
                log "ERROR: pre-flight hook failed (rc=$rc); exiting before the task heartbeat starts"
                exit 75
            fi
            ;;
        legacy-inline)
            log "Pre-flight: TASKPUMP_PRE_FLIGHT unset and legacy markers present — running the transitional inline pre-flight"
            legacy_pre_flight
            ;;
        *)
            log "Pre-flight: none configured (set TASKPUMP_PRE_FLIGHT to run one)"
            ;;
    esac
}

# ── Startup ───────────────────────────────────────────────────────────────────

determine_pre_flight

if [[ "$TEST_MODE" != "plan" ]]; then
    install_credentials
    run_pre_flight

    # After the hook, not before: a hook that writes into the agent's home (an
    # agent settings file, say) does so as root, and the session runs as the
    # unprivileged container user.
    chown -R "$CONTAINER_USER:$CONTAINER_USER" "$AGENT_CLAUDE_DIR" "$AGENT_CLAUDE_JSON" 2>/dev/null || true
    chmod -R u+rw "$AGENT_CLAUDE_DIR" 2>/dev/null || true
    chmod u+rw "$AGENT_CLAUDE_JSON" 2>/dev/null || true
    log "Credentials + agent settings configured"
    log "permission mode: $(jq -r '.permissions.defaultMode // "default"' "$AGENT_CLAUDE_DIR/settings.json" 2>/dev/null)"
fi

# ── Git HTTPS auth: the credential-helper text ───────────────────────────────
# Configured for the unprivileged user below; reads the token from the calling
# git process's environment AT USE TIME. The text itself contains no secret —
# the single quotes survive into git's config, so $GITHUB_TOKEN is expanded by
# the helper's shell when git invokes it, never on any command line. Never
# interpolate the token's VALUE into this string, into git config, or into the
# session script: argv is world-readable via /proc/<pid>/cmdline (issue #14).
GIT_CRED_HELPER='!f() { echo username=x-access-token; echo "password=$GITHUB_TOKEN"; }; f'

if [[ -z "$TEST_MODE" ]]; then
    # ── Background credential refresher ───────────────────────────────────────
    # Periodically re-copies credentials (and the agent config) from the live
    # read-only mount so a long-running container tracks host token refreshes and
    # does not 401 once the startup token's TTL elapses. Runs as root in a child
    # subshell; container teardown (or the `exec` below) reaps it — no explicit
    # cleanup needed. A failed tick (`|| true`) never kills the loop.
    (
        while true; do
            sleep "$CRED_REFRESH_INTERVAL_S"
            refresh_credentials || true
        done
    ) &
    log "Credential refresher started (interval=${CRED_REFRESH_INTERVAL_S}s, pid=$!)"

    # ── Git HTTPS auth ────────────────────────────────────────────────────────
    # A credential helper, not url.insteadOf: the insteadOf form embedded the
    # token in this su's argv AND persisted it into ~/.gitconfig. The helper
    # text is secret-free (see GIT_CRED_HELPER above), so this argv is safe.
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        su "$CONTAINER_USER" -c "git config --global credential.'https://github.com'.helper '$GIT_CRED_HELPER'"
        log "Git HTTPS auth configured (helper reads GITHUB_TOKEN from the environment)"
    else
        log "WARNING: GITHUB_TOKEN not set; ledger fetch + gh will fail"
    fi

    # ── Read-only-primary self-check ──────────────────────────────────────────
    # The primary source tree is mounted read-only; only the workspace, .git, and
    # the ledger are writable. A writable primary root means the mount set
    # regressed to a blanket RW REPO_ROOT — flag it loudly, because a silent
    # regression here lets an agent edit the primary checkout out from under
    # every other worktree.
    if touch "$REPO_ROOT/$RO_PROBE_FILE" 2>/dev/null; then
        rm -f "$REPO_ROOT/$RO_PROBE_FILE" 2>/dev/null || true
        echo "WARNING: primary checkout ($REPO_ROOT) is WRITABLE — read-only mount regression" | tee -a "$LOG_FILE" >&2
    else
        log "mount self-check: primary checkout is read-only (expected)"
    fi
fi

# ── Resolve the kickoff brief (the agent's prompt) ────────────────────────────
if [[ -z "$BRIEF" ]]; then
    echo "ERROR: no brief set (TASKPUMP_BRIEF / ARACHNE_BRIEF); this runner requires an assigned brief" | tee -a "$LOG_FILE" >&2
    exit 1
fi
# Allow brief paths relative to the ledger checkout, the repo root, or the workspace.
if [[ ! -f "$BRIEF" ]]; then
    for cand in "$LEDGER_REPO/$BRIEF" "$REPO_ROOT/$BRIEF" "$WORKSPACE_PATH/$BRIEF"; do
        if [[ -f "$cand" ]]; then BRIEF="$cand"; break; fi
    done
fi
[[ -f "$BRIEF" ]] || { echo "ERROR: brief not found: $BRIEF" | tee -a "$LOG_FILE" >&2; exit 1; }
log "Brief: $BRIEF"

# Optional resume preamble. Bind-mounted at the same absolute path as the host,
# so the env value resolves directly; fall back to the conventional location.
if [[ -n "$RESUME_NOTE" && ! -f "$RESUME_NOTE" && -f "$WORKSPACE_PATH/$RESUME_NOTE_NAME" ]]; then
    RESUME_NOTE="$WORKSPACE_PATH/$RESUME_NOTE_NAME"
fi
if [[ -n "$RESUME_NOTE" && -f "$RESUME_NOTE" ]]; then
    log "Resume preamble: $RESUME_NOTE (prepended to brief)"
else
    RESUME_NOTE=""
fi

# ── Goal preamble ─────────────────────────────────────────────────────────────
# Every task handed to an agent gets a clear goal up front. Read the lead task's
# one-line goal from its task file and write a small preamble that is prepended
# to the brief on stdin ahead of any resume note — mirroring the resume-preamble
# mechanism, so hand-authored briefs stay pure.
#
# SPEC_GAP: this reads the task file directly rather than asking the task CLI,
# because the CLI lives in the workspace and its output format is the consumer's
# to change. The cost is that the ledger's on-disk layout is known in two places.
GOAL_NOTE=""
if [[ -n "$TASK_ID" ]]; then
    GOAL_TEXT="$(yq --front-matter=extract '.goal' "$TASKS_DIR/${TASK_ID}${TASK_FILE_EXT}" 2>/dev/null || echo '')"
    if [[ "$GOAL_TEXT" == "null" ]]; then GOAL_TEXT=""; fi
    if [[ -n "$GOAL_TEXT" ]]; then
        GOAL_NOTE="$WORKSPACE_PATH/$GOAL_NOTE_NAME"
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
        log "Goal: $GOAL_TEXT"
    else
        log "WARNING: lead task ${TASK_ID} has no goal — set one with '$WORKSPACE_TASK_CLI goal ${TASK_ID} --set \"...\"'"
    fi
fi

# ── Stdin assembly ────────────────────────────────────────────────────────────
# Order is load-bearing: goal, then resume context, then the brief. The goal is
# first because it is what the other two are in service of; a resume note read
# after the brief would look like an amendment rather than the premise it is.
PROMPT_PARTS=()
if [[ -n "$GOAL_NOTE" && -f "$GOAL_NOTE" ]]; then PROMPT_PARTS+=("$GOAL_NOTE"); fi
if [[ -n "$RESUME_NOTE" && -f "$RESUME_NOTE" ]]; then PROMPT_PARTS+=("$RESUME_NOTE"); fi
PROMPT_PARTS+=("$BRIEF")

PROMPT_ARGS=""
for part in "${PROMPT_PARTS[@]}"; do
    PROMPT_ARGS+="$(printf '%q' "$part") "
done

if [[ -n "$TEST_MODE" && "$TEST_MODE" != "script" ]]; then
    # Deterministic, greppable report of everything resolution decided.
    echo "REPORT workspace=$WORKSPACE_PATH"
    echo "REPORT repo_root=$REPO_ROOT"
    echo "REPORT ledger_repo=$LEDGER_REPO"
    echo "REPORT tasks_dir=$TASKS_DIR"
    echo "REPORT task_id=$TASK_ID"
    echo "REPORT phase=$PHASE"
    echo "REPORT model=$AGENT_MODEL"
    echo "REPORT max_turns=$MAX_TURNS"
    echo "REPORT safety_turns=$SAFETY_TURNS"
    echo "REPORT task_cli=$TASK_CLI"
    echo "REPORT container_user=$CONTAINER_USER"
    echo "REPORT container_home=$CONTAINER_HOME"
    echo "REPORT pre_flight=$PRE_FLIGHT_PLAN"
    echo "REPORT prompt_parts=${PROMPT_PARTS[*]}"
    exit 0
fi

chmod 666 "$LOG_FILE"
chown -R "$CONTAINER_USER:$CONTAINER_USER" "$LOG_FILE" 2>/dev/null || true

echo | tee -a "$LOG_FILE"
log "Starting single Auto Mode session"
log "  Workspace: $WORKSPACE_PATH"
log "  Task:      ${TASK_ID:-<none>}"
log "  Model:     $AGENT_MODEL    Max turns: $MAX_TURNS"
echo | tee -a "$LOG_FILE"

# The single unprivileged-user session script. Captured in a variable so it can
# be run either with `exec` (default) or wrapped in `timeout` (when a wall-clock
# cap is set) without duplicating the body. Host-side vars are expanded here at
# assignment; `\$...` stay literal for the session shell to expand at run time.
DEV_SESSION_SCRIPT="
    cd '$WORKSPACE_PATH'
    export PATH=/usr/local/cargo/bin:\$PATH
    # By NAME only: the value arrives through the environment (docker -e, then
    # su's env passthrough). Interpolating it here put the secret in this
    # script — the argv of a many-hour su process, world-readable in
    # /proc/<pid>/cmdline (issue #14).
    export GITHUB_TOKEN
    export CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1
    export DISABLE_TELEMETRY=1
    export DISABLE_ERROR_REPORTING=1

    # All task-state operations target the canonical ledger checkout; code
    # productivity is measured against the workspace (this branch). Both
    # spellings are exported: the canonical one for a migrated task CLI, the
    # legacy one for a consumer shim that has not migrated yet.
    export TASKPUMP_TASKS_DIR='$TASKS_DIR'
    export TASKPUMP_TASK_OUT='$TASK_OUT'
    export TASKPUMP_CODE_REPO='$WORKSPACE_PATH'
    export TASKPUMP_TASK_PUSH=1
    export ARACHNE_TASKS_DIR='$TASKS_DIR'
    export ARACHNE_TASK_OUT='$TASK_OUT'
    export ARACHNE_CODE_REPO='$WORKSPACE_PATH'
    export ARACHNE_TASK_PUSH=1

    CURRENT_BRANCH=\$(git -C '$WORKSPACE_PATH' branch --show-current)
    echo \"Branch: \$CURRENT_BRANCH\" | tee -a '$LOG_FILE'

    # Safety-net claim of the lead task (the agent re-claims/sub-claims as the
    # brief directs). Harmless if already claimed by this branch (idempotent).
    if [ -n '$TASK_ID' ]; then
        '$TASK_CLI' claim '$TASK_ID' --branch \"\$CURRENT_BRANCH\" --turns $SAFETY_TURNS 2>&1 | tee -a '$LOG_FILE' || true
        '$TASK_CLI' heartbeat '$TASK_ID' --start 2>&1 | tee -a '$LOG_FILE' || true
    fi

    # ── The single long session ──────────────────────────────────────────────
    # --permission-mode auto: the server-side classifier gates dangerous actions;
    # no --dangerously-skip-permissions. In headless -p, the session aborts after
    # repeated classifier blocks; we treat that as park-for-review.
    # Stdin order: goal preamble, then resume preamble (if any), then the brief.
    cat $PROMPT_ARGS | claude -p \
        --permission-mode auto \
        --model '$AGENT_MODEL' \
        --verbose \
        --output-format stream-json \
        --max-turns $MAX_TURNS \
        2>&1 | tee -a '$LOG_FILE'
    SESSION_RC=\$?
    echo \"Session exited (rc=\$SESSION_RC)\" | tee -a '$LOG_FILE'

    # End heartbeat only if the agent left the lead task in_progress (i.e. didn't
    # call complete/block itself). Never auto-complete: 'done' requires the agent
    # to have asserted green build + tests + PR via the task CLI's complete verb.
    if [ -n '$TASK_ID' ]; then
        TASK_FILE='$TASKS_DIR/$TASK_ID$TASK_FILE_EXT'
        TASK_STATUS=\$(yq --front-matter=extract '.status' \"\$TASK_FILE\" 2>/dev/null || echo '')
        if [ \"\$TASK_STATUS\" = 'in_progress' ]; then
            '$TASK_CLI' heartbeat '$TASK_ID' --end 2>&1 | tee -a '$LOG_FILE' || true
            echo \"Lead task $TASK_ID left in_progress — parked for review.\" | tee -a '$LOG_FILE'
        else
            echo \"Lead task $TASK_ID final status: \$TASK_STATUS\" | tee -a '$LOG_FILE'
        fi
    fi

    # Push the ledger so the host + monitor see final state.
    (cd '$LEDGER_REPO' && git push 2>&1) | tee -a '$LOG_FILE' || true
    echo \"Agent finished at \$(date -u).\" | tee -a '$LOG_FILE'
"

# TASKPUMP_ENTRYPOINT_TEST_MODE=script: print the credential-helper text and
# the assembled session script, then exit before the privilege drop. The suite
# plants a canary token and asserts the secret appears in neither — by NAME
# only (issue #14).
if [[ "$TEST_MODE" == "script" ]]; then
    echo "REPORT git_cred_helper=$GIT_CRED_HELPER"
    printf '%s\n' "$DEV_SESSION_SCRIPT"
    exit 0
fi

# ── The privilege drop: setpriv on a script file, never su -c ─────────────────
# su(1) sets itself as a child subreaper, so every orphaned grandchild of the
# many-hour session — tool subprocesses that outlive their immediate parent —
# reparented to `su`, which sits blocked waiting on its one direct child and
# never reaps them: zombies accumulated at the agent's tool-call rate for the
# life of the session (issue #15). setpriv changes ids and EXECS — no
# intermediary lingers — so orphans reparent to PID 1, the tini that
# runner.sh's `--init` installs, and are reaped there.
#
# Two consequences of losing su, handled here:
#   * su chose the target user's HOME/USER/LOGNAME/SHELL; setpriv touches ids
#     only, so the session identity is set explicitly.
#   * the script rides a root-owned FILE instead of -c argv — a session script
#     in the argv of the longest-lived process in the container was always
#     wrong (/proc/<pid>/cmdline is world-readable; issue #14's surface).
SESSION_SCRIPT_FILE="${TMPDIR:-/tmp}/.taskpump-session.sh"
printf '%s\n' "$DEV_SESSION_SCRIPT" > "$SESSION_SCRIPT_FILE"
chmod 0644 "$SESSION_SCRIPT_FILE"
SESSION_LAUNCH=(
    env HOME="$CONTAINER_HOME" USER="$CONTAINER_USER" LOGNAME="$CONTAINER_USER" SHELL=/bin/bash
    setpriv --reuid "$CONTAINER_USER" --regid "$(id -g "$CONTAINER_USER")" --init-groups
    bash "$SESSION_SCRIPT_FILE"
)

# ── Launch the session: optional wall-clock backstop, else exec ────────────────
# The wall-clock cap is opt-in (unset = the plain exec path) and acts as a
# last-resort guard below the token TTL. `timeout` needs a child to signal, so we
# cannot `exec` in that branch. `|| WALL_RC=$?` keeps `set -e` from aborting
# before we capture rc.
if [[ -n "$AGENT_WALL_TIMEOUT_S" ]]; then
    log "Wall-clock cap: ${AGENT_WALL_TIMEOUT_S}s"
    WALL_RC=0
    timeout "$AGENT_WALL_TIMEOUT_S" "${SESSION_LAUNCH[@]}" || WALL_RC=$?
    if [[ "$WALL_RC" -eq 124 ]]; then
        echo "$(date -u) [wall-cap] session killed by wall-clock timeout (${AGENT_WALL_TIMEOUT_S}s)" | tee -a "$LOG_FILE"
    fi
    exit "$WALL_RC"
else
    exec "${SESSION_LAUNCH[@]}"
fi
