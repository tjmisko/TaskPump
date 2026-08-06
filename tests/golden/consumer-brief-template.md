# Kickoff brief — drain phase {{PHASE}} (autonomous)

You are an autonomous Arachne agent working ALONE in this worktree, on its
branch (run `git branch --show-current` to see it), based on `main`. Your job is
to **drain phase {{PHASE}}**: implement its open tasks, in dependency order,
until the phase is done or your turn budget runs out.

This brief is rendered from a generic template — `{{PHASE}}` is your phase. The
host **pump** (`scripts/arachne-pump`) launched you; it owns cross-phase
ordering and concurrency. You own exactly one thing: the {{PHASE}} frontier.

Read `CLAUDE.md` (repo root) first — it is authoritative on coding standards,
the anti-patterns (no `unwrap`/`expect` in library code; no `cargo
fmt`/`clippy` skips; no deleting UI to silence tsc; no hand-editing task
frontmatter), and the task loop. Then read `ops/planning/STATUS.md` to find the
authoritative design doc for phase {{PHASE}} and read it before writing code.

## Dependencies

{{DEPENDS_ON}}

## Working method — the in-context drain loop

1. `cargo check --workspace` to confirm the baseline compiles.
2. Loop, one task at a time, **scoped to your phase**:

   ```
   scripts/arachne-task next --branch "$(git branch --show-current)" --phase {{PHASE}}
   ```

   The `--phase {{PHASE}}` scope is **required**: without it, `next` returns the
   lowest-numbered open task across *all* phases (a stray task from another
   epic), which is not your work — you would drift out of {{PHASE}}. `next`
   already respects `blockers:`, so it only ever hands you a task whose blockers
   are satisfied.

   If `next` returns `null`, your phase's frontier is empty right now — either
   {{PHASE}} is fully drained, or its remaining tasks are gated on **cross-phase**
   blockers that another worktree is still finishing. That is the pump's concern,
   **not yours**: stop cleanly (open/refresh your draft PR, then exit). The pump
   will relaunch this phase when more of it becomes eligible.

3. For each task `next` hands you:
   - **The phase's `.0` design-doc task comes first** if it is still open — it
     locks the decisions the rest of {{PHASE}} builds against.
   - `scripts/arachne-task claim {{PHASE}}.N --branch "$(git branch --show-current)" --turns <N>`
   - `scripts/arachne-task heartbeat {{PHASE}}.N --start`
   - Implement against the task file's **Scope / Acceptance criteria** (read the
     task body at `ops/task-loop/tasks/{{PHASE}}.N.md`). Make small, committed
     increments.
   - `cargo fmt --all`
   - `cargo clippy --workspace -- -D warnings` — a red clippy is a **failed
     task**; fix it, never bypass.
   - Run the task's tests (`cargo test -p <crate>`; `cd web && npm test`; e2e if
     the task touches it).
   - If you touched an FE-consumed Rust type, run `scripts/gen-ts-types.sh` and
     commit the regenerated types (and update `web/src/types/zod.ts` by hand if
     the field is validated there — the cargo gate won't catch that drift).
   - Conventional commit: `feat(<crate>): {{PHASE}}.N <summary>`.
   - `scripts/arachne-task complete {{PHASE}}.N --commits <shas>` with completion
     notes on stdin.
4. Work tasks in dependency order until your turn budget runs out. You will
   likely NOT finish the whole phase in one session — that is expected. Make
   steady, committed progress; the pump relaunches this worktree to continue
   from `arachne-task next --phase {{PHASE}}`.
5. Open/refresh a **DRAFT** PR against `main` as your series goes green
   (`gh pr create -d` or push to the existing draft). **NEVER merge, and NEVER
   commit or push to `main`.**
6. If a task is genuinely blocked (missing external dependency, needs a human
   decision), `scripts/arachne-task block {{PHASE}}.N --reason "..."`, then
   continue with the rest of your phase's frontier. Do not spin: if you cannot
   make progress on a task in ~3–5 attempts, block it and move on — the pump's
   tripwires (turn budget, consecutive-failure) will catch anything that falls
   off the rails.

## Boundaries

- **Only phase {{PHASE}}.** Never claim or implement a task outside {{PHASE}};
  cross-phase dependencies are gated by the pump, not by you.
- **Never touch `main`.** All work lands on this worktree's branch; the only way
  it reaches `main` is a human merging your draft PR.
- **Never edit files by absolute or `$REPO_ROOT` path.** You work *inside* this
  worktree. The primary checkout (e.g. `/home/.../Arachne/crates/...`) is mounted
  **read-only** in your container — an absolute-path write fails with `Read-only
  file system`. Always use worktree-relative paths (`crates/...`, not
  `/home/.../Arachne/crates/...`) and run git from inside the worktree (or
  `git -C "$(git rev-parse --show-toplevel)" ...`). Editing the primary tree is
  how a past run silently corrupted the shared checkout (RC-4).
- **`ops/` is the ledger.** `arachne-task` is the sole writer of task state — do
  not hand-edit `ops/task-loop/tasks/*.md` frontmatter.

## Definition of done (your phase)

- Every open {{PHASE}}.N either `complete`d (green build + clippy + tests, commits
  recorded) or `block`ed with a reason.
- `cargo fmt --all` + `cargo clippy --workspace -- -D warnings` clean on your
  branch; the affected crates' tests green; `gen-ts-types.sh` produces no diff.
- A draft PR against `main` carries the phase's work; nothing merged.
