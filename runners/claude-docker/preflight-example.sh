#!/bin/bash
# runners/claude-docker/preflight-example.sh — EXAMPLE, NOT WIRED.
#
# This is the project-specific half of what used to be one monolithic
# entrypoint: everything that knows the shape of a particular consumer's repo,
# toolchain, and network. It is reproduced here verbatim from Arachne's
# entrypoint-parallel.sh so that the reference implementation of a pre-flight
# hook is a real one that is known to work, not a sketch.
#
# TaskPump ships it as an example and never runs it. Nothing in TaskPump reads
# this path. To make it live, a consumer bakes it into its agent image and
# points the hook at it:
#
#     # Dockerfile
#     COPY preflight.sh /preflight.sh
#     RUN chmod +x /preflight.sh
#
#     # taskpump.conf (or the environment)
#     TASKPUMP_PRE_FLIGHT=/preflight.sh
#
# ── The contract with entrypoint.sh ──────────────────────────────────────────
#
# The hook runs as root, inside the container, after credentials are installed
# and before the agent session starts. The entrypoint exports:
#
#   WORKSPACE_PATH   the agent's workspace (container workdir)
#   REPO_ROOT        the primary checkout, mounted read-only
#   LEDGER_REPO      the ledger checkout, mounted read-write
#   LOG_FILE         the agent log; append to it to appear in the monitor
#   TASKPUMP_CONTAINER_USER / TASKPUMP_CONTAINER_HOME
#                    the unprivileged user the session will run as, and its home
#   TASKPUMP_TASK_ID / TASKPUMP_PHASE
#                    what this container was launched to work on
#
# A non-zero exit aborts the launch with exit 75 (EX_TEMPFAIL) — before the task
# heartbeat starts, so a failed pre-flight never burns an iteration on the task's
# tripwire counter. Decide *inside* the hook which of its steps are fatal: the
# firewall below is (an agent with unrestricted egress is not the sandbox anyone
# agreed to), the smoke test deliberately is not.
#
# ── Ordering note ────────────────────────────────────────────────────────────
#
# In the pre-split entrypoint the firewall was configured first, before
# credentials were copied. It now runs after, because the settings merge below
# has to overwrite a settings.json that the credential copy may have just laid
# down, and one hook point cannot be both before and after that copy. Nothing
# egresses during the credential copy — it is local file I/O against a read-only
# bind mount — so the window the reorder opens carries no traffic.

set -euo pipefail

: "${WORKSPACE_PATH:=/workspace}"
: "${REPO_ROOT:=$WORKSPACE_PATH}"
: "${LOG_FILE:=$WORKSPACE_PATH/.taskpump-agent.log}"

# ── Firewall ───────────────────────────────────────────────────────────────────
# Egress allowlist. This is the hard sandbox; the permission classifier is the
# second layer, not the first. Refresh the GitHub CIDR ranges from
# api.github.com/meta when pushes start failing.
echo "Configuring firewall..." | tee -a "$LOG_FILE"
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
echo "Firewall configured" | tee -a "$LOG_FILE"

# ── Agent settings: MCP config + Auto Mode allow rules ─────────────────────────
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

# ── Smoke test ─────────────────────────────────────────────────────────────────
# Deliberately non-fatal: a smoke failure is worth shouting about but is not
# worth refusing to run the session over.
echo "Running smoke test..." | tee -a "$LOG_FILE"
WORKSPACE_PATH="$WORKSPACE_PATH" /smoke_test.sh 2>&1 | tee -a "$LOG_FILE" \
    || echo "WARNING: Smoke test had failures (continuing)" | tee -a "$LOG_FILE"

echo "Pre-flight complete" | tee -a "$LOG_FILE"
