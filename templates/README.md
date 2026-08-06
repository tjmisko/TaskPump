# Templates

Prompt text the pump renders and hands to an agent. Both files ship as
**generic defaults**: tool-agnostic, no build system named, no repo layout
assumed. They exist so a fresh consumer is not dead on arrival — the pump
refuses to start without a brief template — and as the starting point for
writing your own.

A consumer overrides them by pointing the relevant key at its own file. The
consumer's copy is where project-specific instructions belong (which build
command, which lint gate, where the design docs live); keep these two generic so
the next consumer inherits something usable.

| File | Rendered by | Key | Handed to the agent as |
|---|---|---|---|
| `phase-drain-brief.md` | once per launch | `TASKPUMP_PHASE_BRIEF_TEMPLATE` | the kickoff brief |
| `resume-note.md` | only when resuming a stalled claim | `TASKPUMP_RESUME_TEMPLATE` | a preamble ahead of the brief |

Stdin order at the container is **goal note, then resume note, then brief** —
see `runners/claude-docker/README.md`.

## Placeholders

Two kinds, because one substitution rule cannot serve both.

**Scalar** — `{{NAME}}` is replaced wherever it appears, including mid-sentence.
Values are single-line and must be safe to substitute textually.

**Block** — `{{NAME}}` occupies a line by itself and the *whole line* is
replaced by a multi-line chunk. A scalar substitution cannot do this: the value
contains newlines, and a mid-line match would produce ragged output. Keep block
placeholders alone on their line, and note that indentation is not reapplied to
the inserted lines.

### `phase-drain-brief.md`

| Placeholder | Kind | Value |
|---|---|---|
| `{{PHASE}}` | scalar | The phase this worktree drains, e.g. `F55`. |
| `{{BASE}}` | scalar | The integration base branch the worktree was cut from, e.g. `main`. |
| `{{TASK_CLI}}` | scalar | How the agent invokes the task CLI in its workspace. |
| `{{TASK_CLI_NAME}}` | scalar | The CLI's basename, for prose that names the tool. |
| `{{TASK_DIR}}` | scalar | The tasks directory relative to the workspace, e.g. `ops/task-loop/tasks`. |
| `{{VERIFY_CMDS}}` | scalar | The per-task verify commands, semicolon-joined onto one line. |
| `{{PROJECT_BRIEF}}` | block | `TASKPUMP_PROJECT_BRIEF` — a paragraph pointing the agent at the project's own docs. |
| `{{DEPENDS_ON}}` | block | Cross-phase dependency summary, or a line stating there are none. |

### `resume-note.md`

| Placeholder | Kind | Value |
|---|---|---|
| `{{TASK_ID}}` | scalar | The stalled task, e.g. `F79.4`. |
| `{{PHASE}}` | scalar | Its phase, e.g. `F79`. |
| `{{BRANCH}}` | scalar | The worktree's branch. |
| `{{TASK_CLI}}` | scalar | How the agent invokes the task CLI in its workspace. |
| `{{TASK_CLI_NAME}}` | scalar | The CLI's basename, for prose that names the tool. |
| `{{TASK_FILE}}` | scalar | Path to the task file, so the prose need not hardcode the ledger layout. |
| `{{COMMITS}}` | block | `git log --oneline <base>..<branch>` — what the dead session already landed. |
| `{{STATUS_SHORT}}` | block | `git status --short`. |
| `{{DIFF_STAT}}` | block | `git diff --stat`. |
| `{{VERIFY_CMDS}}` | scalar | The project's format/lint/test commands, semicolon-joined onto one line; must be clean before a task can be completed. |

`{{VERIFY_CMDS}}` is deliberately **not** called `BUILD_GATE`. `TASKPUMP_BUILD_GATE`
already means something else — the merge queue's gate, which decides whether a
branch may join the integration trunk. These are the per-task commands an agent
runs before `complete`. One tool with two meanings for "build gate" would
eventually cost someone an afternoon.

A template must leave **no unsubstituted `{{...}}`** after rendering. That is
asserted by the test suite: an unknown placeholder reaches the agent as literal
noise, and a renamed one silently drops the information it was carrying.

## Why the resume note says what it says

The wording is not incidental. A pump was found idling 563 ticks over seven
hours on a task whose agent had exited cleanly believing the frontier was
drained: the task was still claimed, `next` and `ready` surface only `open`
tasks, so `next` returned `null` and the agent read that as "nothing left to
do". Everything blocked behind it stayed blocked while the supervisor reported
healthy.

So the note leads with **don't run `next`**, tells the agent to read the task
file directly, shows it what the dead session already committed, and insists on
one of three endings — finish, split, or block. All three release the tasks
behind it; leaving the claim in place does not.
