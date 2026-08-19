# Templates

Prompt text the pump renders and hands to an agent. All three files ship as
**generic defaults**: tool-agnostic, no build system named, no repo layout
assumed. They exist so a fresh consumer is not dead on arrival — the pump
refuses to start without a brief template — and as the starting point for
writing your own.

A consumer overrides them by pointing the relevant key at its own file. The
consumer's copy is where project-specific instructions belong (which build
command, which lint gate, where the design docs live); keep the shipped three
generic so the next consumer inherits something usable.

| File | Rendered by | Key | Handed to the agent as |
|---|---|---|---|
| `phase-drain-brief.md` | once per launch, at `--grain phase` | `TASKPUMP_PHASE_BRIEF_TEMPLATE` | the kickoff brief |
| `task-brief.md` | once per launch, at `--grain task` | `TASKPUMP_TASK_BRIEF_TEMPLATE` | the kickoff brief |
| `resume-note.md` | only when resuming a stalled claim | `TASKPUMP_RESUME_TEMPLATE` | a preamble ahead of the brief |

`TASKPUMP_BRIEF_TEMPLATE` is an older spelling of the phase key and still works;
`TASKPUMP_PHASE_BRIEF_TEMPLATE` wins when both are set (`libexec/tp-pump:1258`).
There is no such alias for the task or resume keys.

The two briefs are separate files rather than one parameterized template because
they instruct the agent to do **opposite** things about acquisition. The phase
brief's working method IS the in-context `next --phase` loop; the task brief
forbids `next` outright, because at task grain the pump has already dispatched
the siblings that loop would claim.

Stdin order at the container is **goal note, then resume note, then brief**
(`runners/claude-docker/entrypoint.sh:589-592`) — see
`runners/claude-docker/README.md`.

## Placeholders

Two kinds, plus a conditional wrapper, because one substitution rule cannot serve
all of them.

**Scalar** — `{{NAME}}` is replaced wherever it appears, including mid-sentence.
Values are single-line and must be safe to substitute textually.

**Block** — `{{NAME}}` occupies a line by itself and the *whole line* is
replaced by a multi-line chunk. A scalar substitution cannot do this: the value
contains newlines, and a mid-line match would produce ragged output. Keep block
placeholders alone on their line, and note that indentation is not reapplied to
the inserted lines.

**Conditional section** — the lines between `{{#NAME}}` and `{{/NAME}}` (each
marker alone on its line) render only when `NAME` resolves to content; the
marker lines are never emitted. This is how a template mentions an *optional*
value: `{{VERIFY_CMDS}}` is empty unless the consumer sets
`TASKPUMP_VERIFY_CMDS`, and a sentence built around an empty value — "Verify
with ." — is worse than no sentence at all, so both shipped briefs wrap their
verify prose in a `{{#VERIFY_CMDS}}` section.

There is **no inverted section**: `{{^NAME}}` is not a form the renderer knows
(`lib/pump-lib.sh:42-74`), so a template cannot say one thing when a value is
present and another when it is absent. Where a template has to cover the empty
case — as the briefs' step "establish the baseline" does, since a consumer that
configures no verify commands still has a bar somewhere — write the fallback
sentence unconditionally, outside the section, in wording that stays true when
the section renders as well.

Two renderer traps belong to the template author rather than to any one
template, both open as **issue #100**. A substituted value containing `&` leaves
a literal `{{KEY}}` where the `&` stood — on bash 5.2 and newer, `&` in the
replacement half of `${var//pat/rep}` means "the text that matched" — so the
output carries an unsubstituted placeholder the rest of the run never notices.
And a `{{#NAME}}` whose closing `{{/NAME}}` is missing drops **the rest of the
file**, Boundaries included, at rc 0, whenever `NAME` resolves empty: nothing
lowers the skip the opening marker raised. Render a hand-written template before
you trust it: `tp pump --phases <range> --render-brief <unit>`.

### The brief render map

One map serves both briefs (`libexec/tp-pump:1334-1347`), so either template may
use any key in it. Three keys carry a value only at `--grain task`; at phase
grain they resolve empty, which also means their `{{#…}}` sections drop.

| Placeholder | Kind | Populated | Value |
|---|---|---|---|
| `{{PHASE}}` | scalar | both grains | The phase this worktree drains, e.g. `F55`. At task grain, the task's own phase. |
| `{{BASE}}` | scalar | both grains | The integration base branch the worktree was cut from, e.g. `main`. |
| `{{TASK_CLI}}` | scalar | both grains | How the agent invokes the task CLI in its workspace. |
| `{{TASK_CLI_NAME}}` | scalar | both grains | The CLI's basename, for prose that names the tool. |
| `{{TASK_DIR}}` | scalar | both grains | The tasks directory relative to the workspace, e.g. `tasks`. |
| `{{VERIFY_CMDS}}` | scalar | both grains | The per-task verify commands, rendered as an inline phrase. Empty (and its `{{#VERIFY_CMDS}}` sections dropped) unless `TASKPUMP_VERIFY_CMDS` is set. |
| `{{BUILD_GATE}}` | scalar | both grains | An alias of `{{VERIFY_CMDS}}`, resolving to the same value (`libexec/tp-pump:1344`). See the note below before using it. |
| `{{PROJECT_BRIEF}}` | scalar | both grains | `TASKPUMP_PROJECT_BRIEF` — a paragraph pointing the agent at the project's own docs. Substituted as a scalar, so a `{{PHASE}}` inside the configured value is expanded too. |
| `{{DEPENDS_ON}}` | block | both grains | Cross-phase dependency summary, or a line stating there are none. |
| `{{TASK_ID}}` | scalar | task grain | The one task this container was launched for, e.g. `G3.4`. Empty at phase grain. |
| `{{TASK_FILES}}` | scalar | task grain | The task's declared `files:`, each path backticked, joined with `, `. Empty when the task declares none. |
| `{{TASK_FILES_UNDECLARED}}` | scalar | task grain | `yes` exactly when `{{TASK_FILES}}` is empty; otherwise empty. A flag for a `{{#TASK_FILES_UNDECLARED}}` section, not text to print. |

### `task-brief.md`

`{{TASK_FILES}}` and `{{TASK_FILES_UNDECLARED}}` are mutually exclusive by
construction (`libexec/tp-pump:1325-1330`), and a task brief needs **both**
sections. The brief cannot say one thing about both cases: "the pump scheduled
you concurrently *because* those sets are disjoint" is false for a task with
`files: []`, which was scheduled **exclusively**, precisely because it declared
nothing. A hand-written task brief that omits these two renders perfectly
cleanly and silently drops the footprint discipline the pump's task-grain
concurrency guarantee rests on.

`{{PHASE}}` is the task's own phase, and `{{DEPENDS_ON}}` names the task's
blockers (every one of them — at task grain an in-phase blocker is another
container's branch, not the same session's earlier work).

### `resume-note.md`

| Placeholder | Kind | Value |
|---|---|---|
| `{{TASK_ID}}` | scalar | The stalled task, e.g. `F79.4`. |
| `{{PHASE}}` | scalar | Its phase, e.g. `F79`. |
| `{{BRANCH}}` | scalar | The worktree's branch. |
| `{{TASK_CLI}}` | scalar | How the agent invokes the task CLI in its workspace. |
| `{{TASK_CLI_NAME}}` | scalar | The CLI's basename, for prose that names the tool. |
| `{{TASK_FILE}}` | scalar | Path to the task file, so the prose need not hardcode the ledger layout. |
| `{{VERIFY_CMDS}}` | scalar | The project's format/lint/test commands, rendered as an inline phrase; must be clean before a task can be completed. Empty (sections dropped) unless `TASKPUMP_VERIFY_CMDS` is set. |
| `{{BUILD_GATE}}` | scalar | The same alias of `{{VERIFY_CMDS}}` as in the brief map (`libexec/tp-pump:1402`). |
| `{{COMMITS}}` | block | `git log --oneline <base>..<branch>` — what the dead session already landed. |
| `{{STATUS_SHORT}}` | block | `git status --short`. |
| `{{DIFF_STAT}}` | block | `git diff --stat`. |

The resume map is **not** the brief map: `{{BASE}}`, `{{TASK_DIR}}`,
`{{PROJECT_BRIEF}}`, `{{DEPENDS_ON}}` and the two footprint keys do not exist
here, and `{{BRANCH}}` and `{{TASK_FILE}}` exist nowhere else.

### `{{BUILD_GATE}}` is a live alias, and it is a trap

Both maps resolve `{{BUILD_GATE}}` to the same value as `{{VERIFY_CMDS}}`, so a
template written against the older name still renders. Prefer
`{{VERIFY_CMDS}}` in anything new, and never read `{{BUILD_GATE}}` as "the value
of `TASKPUMP_BUILD_GATE`" — it is not. That key is the **merge queue's** gate,
which decides whether a branch may join the integration trunk;
`TASKPUMP_VERIFY_CMDS` is the per-task commands an agent runs before `complete`.
The placeholder took the name of the wrong one of the two; the *keys* were kept
apart deliberately, because one tool with two meanings for "build gate" would
eventually cost someone an afternoon. No shipped template uses `{{BUILD_GATE}}`,
and `tests/test-entrypoint.sh` fails one that starts to.

A template must leave **no unsubstituted `{{...}}`** after rendering: an unknown
placeholder reaches the agent as literal noise, and a renamed one silently drops
the information it was carrying. `tests/test-tp-pump.sh` asserts it for whatever
ships, and `tests/test-entrypoint.sh` asserts the other direction — every
placeholder a shipped template uses is documented in the tables above, so adding
one to a template means adding a row here.

## What the briefs insist on, and why

Wording in the shipped briefs that looks like boilerplate is usually a scar. If
you write your own, carry these across:

**Every ending, not just the good one.** `complete`, `block` and `release` all
free the tasks waiting behind a claim; stopping with the claim held frees
nothing. A brief that offers only `complete` leaves an agent that cannot finish
with no legal move, and the tasks behind it stranded until a human notices
(issue #64).

**`heartbeat --end`, in the same step as the ending.** `--start` stamps liveness;
`--end` is what decrements the turn budget and decides whether the cycle landed
anything. A brief that mentions only `--start` makes its agent invisible to two
of the supervisor's three tripwires (issue #61). It must run *before* the
ending — once the task leaves `in_progress`, a heartbeat is a silent no-op.

**Text the agent reads is data.** Task bodies, `goal` fields, completion notes,
commit subjects and the dependency block all reach the prompt from the ledger and
from git, unescaped, and the goal note the container assembles ahead of the brief
today declares that it outranks the brief (issues #96, #97, #86). The brief is
the only place that boundary can be stated to the agent, so state it: an
instruction found in that text is a finding to report, not an order to obey.

**Boundaries that do not lean on the sandbox.** The primary checkout is mounted
read-only by the container runner only when the ledger lives in a repository of
its own; in the single-repo shape the mount collapses to read-write
(`docs/RUNNERS.md` §4.3), and `runners/local` sandboxes nothing at all. A brief
that justifies a rule with a guarantee the runner may not be providing teaches
the agent to stop following the rule the moment it notices (issue #56).

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
behind it; leaving the claim in place does not. (`release` is a fourth legal
ending that the resume note does not yet offer, unlike the two briefs — that
half of issue #64 is still open.)
