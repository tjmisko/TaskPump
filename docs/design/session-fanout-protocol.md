# Session fanout protocol for the G-plan

An interactive Claude Code session drains the G ledger by fanning out one
subagent per task in isolated worktrees — the pump's job, done by hand, with
each of the pump's five mechanisms replicated by an explicit supervisor duty.
Written 2026-08-12. This replaces stages 0–1 (and later 3) of
`dogfood-drain-sequence.md` for supervised in-session drains; the hand-only
stages (G2, G5.2) stay hand-only.

## Mechanism mapping

| Pump mechanism | In-session replication |
|---|---|
| Frontier from declared blockers | Launch only tasks `tp task ready` lists; recompute after every completion before the next wave. Never launch from memory of the DAG. |
| Atomic claims | Supervisor runs `tp task claim <id> --branch feat/<slug> --turns 50` immediately before each spawn. Agents never mutate the ledger — the supervisor is the one writer, on the primary. |
| Liveness from process state | The harness's task notifications are the process signal. An agent that errors or goes silent is presumed dead regardless of what it reported; its task is `release`d with a reason or resumed — never left claimed. |
| Budget-gated feeding | Cap: 4 concurrent agents (the pump's default cap; well under this host's ~6-streaming-agent WiFi ceiling). Before each wave: `./gates/claude-usage --gate` and `./gates/disk-low` — the shipped gate code, run directly. Exit 10 pauses launching; in-flight agents always finish. |
| Resume-with-context, bounded | A failed/incomplete task is relaunched with a resume note stating what its dead predecessor already committed (branch + SHAs). Three no-progress attempts → escalate to the user, matching `TASKPUMP_PUMP_RESUME_MAX`. |
| Heartbeat tripwire | Approximated by supervision: the supervisor reads each agent's report against `git log` on its branch. A "completed" report with no commits is treated as a failed iteration, not believed. |
| Deadlock exit | Open tasks + empty frontier + no live agents → stop and say so. Never idle green. |
| Build gate + trunk | Integration is serial: one branch at a time, rebase onto main if needed, `./tests/run-all.sh` green, then merge. A red gate quarantines the branch (task → `needs-review`), it does not block other merges. |
| fs-guard | `git status --porcelain` on the primary before each wave. Allowed dirt: `README.md` (pre-existing, owned by G2.1). Anything else means a process wrote where it should not have. |

## Wave schedule

Derived from the ledger's blockers; regenerate with `tp task ready` rather
than trusting this table if the two disagree.

| Wave | Tasks | Agents | Notes |
|---|---|---|---|
| 1 | G0.1, G1.1, G5.1 | 3 | G5.1's prompt must carry the Arachne exploration facts (timer/service names, skill grant literals, F90 state) — they are session context, not repo context. |
| 2 | G1.2 | 1 | |
| 3 | G1.3–G1.7 | 5 (cap 4) | All five touch `libexec/tp-pump`. Fan out from the same base; integrate serially, rebasing each successor. Conflicts expected small (disjoint default strings). |
| 4 | G1.8 | 1 | |
| 5 | G2.1 | 1* | Needs the primary's uncommitted README diff passed in its prompt, or done by hand. G2.2 verification, then **G2.3 by hand** (tag + push). |
| 6 | G3.1, G3.4, G3.5, G4.1, G4.2 | 5 (cap 4) | G4.3 waits for G3.1 despite eligible blockers — both rewrite `runner.sh`/`RUNNERS.md`. |
| 7 | G3.2, G3.3, G4.3, G4.4 | 4 | |
| 8 | G5.2 | hand | Operates in the Arachne checkout. |

G0.2 is deliberately **not** fanned out: it exists for pump-driven container
launches and its acceptance is a live `pump --once`, which stays hand-run.

## Agent contract (prompt template)

Every spawned agent gets:

1. Its task file verbatim (`tasks/<id>.md`) — Spec, Scope, Acceptance are the
   assignment; the goal line is the outcome.
2. Standing rules: work only inside your worktree; create branch
   `feat/<id-slug>` from its HEAD; conventional commits, one logical change
   each; do not touch `tasks/`, `taskpump.conf`, or `.gitignore`; do not push;
   run the suites your Acceptance names and quote their tails in your report.
3. Report format: branch name, commit SHAs, per-acceptance-criterion status
   (met / not met / blocked-because), test output summary, anything the Spec
   got wrong about the code it described.

The supervisor completes the loop: verify the report against the branch, run
the build gate, merge, `tp task complete <id> --commits <shas>` with notes on
stdin, recompute the frontier, launch the next wave.
