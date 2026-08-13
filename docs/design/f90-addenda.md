# F90 addenda — two create-ready tasks for Arachne's ops ledger

Drafted under TaskPump task G5.1 from the 2026-08-12 exploration. Two
Arachne-side gaps sit outside F90's current task set (F90.0–F90.7): the live
host services that outlive any drain window, and the prep-long-session skill
whose permission grants name the pre-cutover script paths.

**How to file:** from the Arachne primary checkout, run each `arachne-task
create` command below (the CLI owns the frontmatter), then author the created
file's Spec/Scope/Acceptance sections with the body text that follows it.

**Retirement:** this file is a hand-off buffer, not documentation. Once both
tasks are filed in Arachne's ops ledger, delete `docs/design/f90-addenda.md`
from TaskPump.

---

## F90.8 — Repoint the live host services

```
./scripts/arachne-task create F90.8 --phase F90 \
  --title "Repoint the live host services at the pinned taskpump checkout" \
  --blockers F90.4 \
  --goal "The two always-on host services survive the cutover: arachne-disk-guard.timer's reclaim path execs the pinned taskpump checkout's tp cleanup, the arachne-agent- container prefix and .arachne-agent.log name stay pinned in Arachne's taskpump.conf as the switchboard recorder's match contract, and the swap happens outside a drain window."
```

### Spec

Two systemd --user units run on this host around the clock, independent of any
drain, and both cross the F90.4 cutover live (all verified 2026-08-12):

- **`arachne-disk-guard.timer` is `active`**, firing every ~5 minutes
  (`OnBootSec=5min`, `OnUnitActiveSec=5min`, `AccuracySec=1min`). Its service's
  ExecStart is `/usr/bin/env bash -lc '"$ARACHNE_REPO/scripts/arachne-disk-guard"
  --check'` with `Environment=ARACHNE_REPO=%h/Projects/Arachne`. The guard
  script delegates all reclaim to `$REPO_ROOT/scripts/arachne-cleanup`
  (`arachne-disk-guard:50`, invoked at `:152`), passing compiler-busy
  workspaces via `EXTRA_BUSY_DIRS` — a knob TaskPump's `tp cleanup` still
  honours as `TASKPUMP_EXTRA_BUSY_DIRS`.
- **`arachne-switchboard-recorder.service` is `active`**
  (`ExecStart=%h/go/bin/arachne-switchboard-recorder -interval 5s`). Its match
  contract is `NamePrefix = "arachne-agent"`
  (switchboard-dashboard `internal/arachne/docker.go:16`): a session's slug is
  the container name minus the `arachne-agent-` prefix, and the recorder tails
  `.arachne-agent.log` inside each workspace (`docker.go:73`). Rename either
  and recording silently stops.

After F90.4 the reclaim chain must land in the **pinned** taskpump checkout:
timer → `arachne-disk-guard --check` → `scripts/arachne-cleanup` (now an exec
shim) → `taskpump/libexec/tp-cleanup`. That chain holds only if the shim is in
place and the unit's ExecStart names a path that survives the cutover — verify
it, do not assume it. Because the timer fires every 5 minutes regardless of
what else is running, the swap must happen **outside a drain window**: a
reclaim racing live agents through a half-swapped chain is exactly the failure
the guard exists to prevent.

### Scope

- Confirm (or repoint, reinstalling via `./scripts/arachne-disk-guard
  --install`) the timer's reclaim path so it execs the pinned checkout's
  `tp cleanup`; record which form the ExecStart chain takes.
- Pin `TASKPUMP_AGENT_PREFIX=arachne-agent-` (trailing dash included) and
  `TASKPUMP_AGENT_LOG_NAME=.arachne-agent.log` in Arachne's checked-in
  `taskpump.conf`. These are the recorder's match contract, not cosmetics.
- Leave `arachne-switchboard-recorder.service` itself untouched (F90.7's goal
  already pins this).
- Perform and verify the swap outside a drain window.

### Acceptance

1. `systemctl --user cat arachne-disk-guard.timer arachne-disk-guard.service`
   shows the post-cutover ExecStart — the reclaim chain resolves into the
   pinned taskpump checkout's `tp cleanup`.
2. One full timer firing after the swap reads clean in
   `journalctl --user -u arachne-disk-guard`: the check runs, and reclaim
   either delegates through to `tp cleanup` or correctly skips on a healthy
   disk. No errors, no path-not-found.
3. The recorder still attaches to a test container named with the
   `arachne-agent-` prefix (the session appears in the recorder's history).
4. `taskpump.conf` carries the pinned `TASKPUMP_AGENT_PREFIX` and
   `TASKPUMP_AGENT_LOG_NAME` values.
5. The completion notes record that the swap happened outside a drain window.

---

## F90.9 — Update the prep-long-session skill

```
./scripts/arachne-task create F90.9 --phase F90 \
  --title "Update the prep-long-session skill for the shim-path cutover" \
  --blockers F90.4 \
  --goal "The prep-long-session skill's allowed-tools grants and orient gate match the F90.4 shim paths so it runs end-to-end in a post-F90.4 checkout without a permission prompt, no reference to the files F90.1 deletes remains, and the re-point at bare tp is recorded as a follow-up gated on F90.7."
```

### Spec

The skill at `~/.claude/skills/prep-long-session/SKILL.md` is the operator's
entry point for every long-running Arachne session, and it is coupled to the
pre-cutover script paths in three distinct ways (all verified 2026-08-12):

1. **Permission grants, not just paths.** Its `allowed-tools` frontmatter
   grants these literal Bash prefixes:
   `Bash(./scripts/run-parallel.sh --list)`,
   `Bash(./scripts/run-parallel.sh --dry-run)`,
   `Bash(./scripts/arachne-task list*)`, `Bash(./scripts/arachne-task goal*)`,
   `Bash(./scripts/arachne-task ready*)`,
   `Bash(./scripts/arachne-pump --dry-run*)`,
   `Bash(./scripts/arachne-pump --list*)`,
   `Bash(./scripts/arachne-pump --render-brief*)`,
   `Bash(./scripts/arachne-usage*)` (plus generic `git`/`gh worktree`/
   `printf`/`ls`/`cat`/`wl-copy` grants). A caller-path change makes the
   grant stop matching, so the skill starts throwing permission prompts
   mid-run — the exact failure mode F90.4's shims exist to prevent.
2. **The orient step hard-gates on files existing.** Step 1 requires, on the
   launching branch: `scripts/arachne-pump`, `scripts/arachne-usage`,
   `scripts/arachne-pump-lib.sh` for path A, and `scripts/run-parallel.sh`,
   `entrypoint-parallel.sh`, `claude-settings-auto.json` for path B — "if not,
   surface it and stop."
3. **Path B names files F90.1 deletes.** The v1 manifest run is built on
   `scripts/run-parallel.sh` and `ops/task-loop/parallel-manifest.tsv`, both
   in F90.1's fossil cut.

F90.4 keeps every `scripts/arachne-*` path alive as an exec shim, so the pump
grants should keep matching immediately after F90.4 — verify that end-to-end
rather than assuming it. The permanent breakage is (a) path B, whose substrate
F90.1 deletes, and (b) the whole grant set again once F90.7 retires the shim
layer in favour of bare `tp` — which is why the tp-native re-point is a
recorded follow-up here, not part of this task.

### Scope

- Verify each pump-path grant literal still resolves and matches in a
  post-F90.4 checkout (the shims sit at the granted paths), by running the
  skill end-to-end.
- Remove path B: the two `run-parallel.sh` grants, the [B] orient gate, and
  every [B] step and reference to `run-parallel.sh` /
  `parallel-manifest.tsv`. The skill becomes pump-only; the manifest run's
  history lives in the design docs F90.1 re-homes, not here.
- Keep the [A] orient gate on the shim paths (`scripts/arachne-pump`,
  `scripts/arachne-usage`, `scripts/arachne-pump-lib.sh`) for now — they exist
  post-F90.4.
- Add an explicit note in the skill: after F90.7 retires the shims, re-point
  the `allowed-tools` grants and the orient gate at the bare `tp` entry point.
  That re-point is **blocked on F90.7** and must not be done in this task.
- The skill file lives outside the Arachne repo (`~/.claude/skills/`), so the
  edit is not an Arachne commit; the ledger task tracks the work and its
  verification against an Arachne checkout.

### Acceptance

1. The skill runs end-to-end (steps 1–8) in a post-F90.4 checkout without a
   single permission prompt — every Bash call it makes matches a grant.
2. No reference to files F90.1 deletes remains:
   `rg -n 'run-parallel|parallel-manifest' ~/.claude/skills/prep-long-session/SKILL.md`
   returns nothing.
3. The orient gate names only files that exist post-F90.4, and still fails
   clearly on a branch that predates the shims.
4. The bare-`tp` re-point is recorded in the skill as a follow-up gated on
   F90.7, and is not performed.
