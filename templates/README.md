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
forbids `next` outright, because at task grain acquisition is the pump's — the
next thing `next` returns is a task the pump is entitled to dispatch to a
different container.

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
present and another when it is absent. It fails in the worst available way: the
`{{^NAME}}` line reaches the agent verbatim while its `{{/NAME}}` closer is
consumed, so the body renders unconditionally under a line of literal noise.
Where a template has to cover the empty case — as the briefs' step "establish the
baseline" does, since a consumer that configures no verify commands still has a
bar somewhere — write the fallback sentence unconditionally, outside the section,
in wording that stays true when the section renders as well.

Two renderer traps belong to the template author rather than to any one
template, both open as **issue #100**. First, a substituted value containing `&`
leaves a literal `{{KEY}}` where the `&` stood — bash reads `&` in the
replacement half of `${var//pat/rep}` as "the text that matched" — so the output
carries an unsubstituted placeholder the rest of the run never notices:

```
$ echo 'A: {{PROJECT_BRIEF}}' > /tmp/t.md
$ TASKPUMP_BRIEF_TEMPLATE=/tmp/t.md TASKPUMP_PROJECT_BRIEF='see foo & bar' \
    tp pump --render-brief <phase>
A: see foo {{PROJECT_BRIEF}} bar
```

Second, a `{{#NAME}}` whose closing `{{/NAME}}` is missing drops **the rest of
the file**, Boundaries included, at rc 0, whenever `NAME` resolves empty:
nothing lowers the skip the opening marker raised.

Render a hand-written template before you trust it, **and check which file you
rendered** — the flag picks the template from `--grain`, not from the argument:

```
tp pump --render-brief <phase>              # phase-drain-brief.md
tp pump --grain task --render-brief <task>  # task-brief.md
```

Task grain refuses a phase token (`libexec/tp-pump:2827-2832`). Phase grain
refuses nothing: handed a task id it renders the *phase* brief at rc 0 with
`{{PHASE}}` set to that task id — "drain phase G3.1" — so a task-brief author
who omits `--grain task` verifies the wrong file and sees no error.

Do not add `--phases` to these commands. Both flags write the same variable
(`libexec/tp-pump:341` and `:372`) and the last one on the line wins, so
`--phases G3 --render-brief G3.1` renders a brief for `G3.1` while
`--render-brief G3.1 --phases G3` renders one for `G3` — same flags, different
output, no warning either way.

### The brief render map

One map serves both briefs (`libexec/tp-pump:1334-1347`), so either template may
use any key in it. Three keys carry a value only at `--grain task`; at phase
grain they resolve empty, which also means their `{{#…}}` sections drop.

| Placeholder | Kind | Populated | Value |
|---|---|---|---|
| `{{PHASE}}` | scalar | both grains | The phase this worktree drains, e.g. `F55`. At task grain, the task's own phase. |
| `{{BASE}}` | scalar | both grains | The branch this worktree was cut from. `main` by default (`TASKPUMP_BASE` / `--base`); under `--integration-trunk` with no explicit `--base` it is the trunk instead, `auto/trunk` by default (`libexec/tp-pump:268`, `:405-407`). **Not** a promise about who merges it — see below. |
| `{{TASK_CLI}}` | scalar | both grains | How the agent invokes the task CLI in its workspace. |
| `{{TASK_CLI_NAME}}` | scalar | both grains | The CLI's basename, for prose that names the tool. |
| `{{TASK_DIR}}` | scalar | both grains | The tasks directory relative to the repository root, e.g. `tasks` — absolute if it lives outside it (`tasks_dir_rel`, `libexec/tp-pump:452`). |
| `{{VERIFY_CMDS}}` | scalar | both grains | The per-task verify commands, rendered as an inline phrase. Empty (and its `{{#VERIFY_CMDS}}` sections dropped) unless `TASKPUMP_VERIFY_CMDS` is set. |
| `{{BUILD_GATE}}` | scalar | both grains | An alias of `{{VERIFY_CMDS}}`, resolving to the same value (`libexec/tp-pump:1344`). See the note below before using it. |
| `{{PROJECT_BRIEF}}` | scalar | both grains | `TASKPUMP_PROJECT_BRIEF` — a paragraph pointing the agent at the project's own docs. A `{{PHASE}}` inside the configured value is expanded (`libexec/tp-pump:1345` does it by hand); see the warning below before putting any other placeholder in it. |
| `{{DEPENDS_ON}}` | block | both grains | At phase grain, the phase's cross-phase blockers; at task grain, *every* blocker of the task. Each is resolved to branch / integration state / PR. A line stating there are none when the list is empty. |
| `{{TASK_ID}}` | scalar | task grain | The one task this container was launched for, e.g. `G3.4`. Empty at phase grain. |
| `{{TASK_FILES}}` | scalar | task grain | The task's declared `files:`, each path backticked, joined with `, `. Empty when the task declares none. |
| `{{TASK_FILES_UNDECLARED}}` | scalar | task grain | `yes` exactly when `{{TASK_FILES}}` is empty; otherwise empty. A flag for a `{{#TASK_FILES_UNDECLARED}}` section, not text to print. |

**Do not nest placeholders in `TASKPUMP_PROJECT_BRIEF` beyond `{{PHASE}}`.**
`{{PHASE}}` works because the pump substitutes it into the value before the
value enters the map. Every *other* key is a coin flip: the renderer walks
`TPL_VARS` in bash's hash order and rewrites the line each time, so a key that
happens to be visited after `PROJECT_BRIEF` gets expanded and one visited before
it does not. Measured on this build:

```
$ TASKPUMP_PROJECT_BRIEF='phase={{PHASE}} base={{BASE}} dir={{TASK_DIR}} id={{TASK_ID}}' \
    tp pump --grain task --render-brief G3.2
phase=G3 base=main dir={{TASK_DIR}} id=G3.2
```

`{{TASK_DIR}}` reached the agent as literal noise. The order is not a contract
and may differ on your bash, so verify with the command above rather than
copying the outcome.

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
| `{{COMMITS}}` | block | `git log --oneline <base>..<branch>`, first 40 — what the dead session already landed. |
| `{{STATUS_SHORT}}` | block | `git status --short`, first 40 lines. |
| `{{DIFF_STAT}}` | block | `git diff --stat`, last 20 lines. |

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
eventually cost someone an afternoon. No shipped template uses `{{BUILD_GATE}}`
(`grep -rn BUILD_GATE templates/` hits only this file).

A template must leave **no unsubstituted `{{...}}`** after rendering: an unknown
placeholder reaches the agent as literal noise, and a renamed one silently drops
the information it was carrying.

**The suite checks that for two of the three shipped templates, not three.**
`tests/test-entrypoint.sh:1001-1002` sets `BRIEF_T` to `phase-drain-brief.md` and
`RESUME_T` to `resume-note.md`, and every assertion downstream reads those two
variables: the recorded placeholder sets (`:1012`, `:1017`), the `{{BUILD_GATE}}`
refusal (`:1022`), and the loop that requires each used placeholder to appear in
the tables above (`:1029-1033`). The four leftover-`{{` assertions in the suite
(`tests/test-tp-pump.sh:1228`, `:1259`, `:1273`, `tests/test-entrypoint.sh:1060`)
all render the phase brief or the resume note. `tests/test-pump-task-grain.sh`
does render `task-brief.md` (`:299-345`) but asserts only its step numbering and
its two footprint sentences.

So for `task-brief.md` — and for any template you write yourself — a new
placeholder, an undocumented one, and a `{{BUILD_GATE}}` all pass the suite.
Check those by hand:

```
grep -oE '\{\{[A-Z_]+\}\}' <your-template> | sort -u   # against the tables above
tp pump --grain task --render-brief <task> | grep '{{'  # must print nothing
```

## What the briefs insist on, and why

Wording in the shipped briefs that looks like boilerplate is usually a scar. If
you write your own, carry these across:

**Every ending, not just the good one.** A brief that offers only `complete`
leaves an agent that cannot finish with no legal move, so it stops with the
claim held — and `next` and `ready` surface only `open` tasks, so nothing sees
the task again until a human does (issue #64).

**And what the endings actually do, which is not symmetric.** Say this exactly,
because getting it wrong is worse than omitting it. Only `complete` frees a
task's dependents: `blockers_satisfied` (`libexec/tp-task:514-532`) requires
every blocker to be `status: done`, `complete` is the only verb that writes
`done` (`:1115`), `cmd_block` writes `blocked` (`:1146-1170`) and `cmd_release`
writes `open` (`:1202-1232`). What `block` and `release` do achieve is clearing
`claimed_by` and putting the task into a state a human or the pump can act on;
`release` returns it to the frontier outright. A brief that tells its agent all
three "free what was waiting behind you" has taught it to block liberally, and
every dependent goes ineligible while the phase looks like it is still moving.

**"Never touch `{{BASE}}`" — without promising who does.** Both shipped briefs
used to say the only way work reaches `{{BASE}}` is a human merging the draft
PR. That is false under `--integration-trunk`, the mode in which `{{BASE}}` is
the trunk: `integrate_one_unit_real` (`libexec/tp-pump:1751-1780`) runs
`git merge --no-ff` of the agent's branch into the trunk worktree on every tick
via `reconcile_trunk` (`:1788-1796`), gated only by the build gate — no human,
no PR. The human PR in that mode is trunk → `INTEGRATION_BASE`
(`graduate_trunk`, `:1804`). State the *rule* (you never merge, you never push
to `{{BASE}}`) and leave the graduation mechanism unnamed; an agent that catches
a brief overstating a protection is entitled to distrust the rest of it.

**There is no `{{TURNS}}` placeholder, so do not print `--turns <N>`.** The
brief map carries no turn budget (`libexec/tp-pump:1334-1347`), so a template
that writes `claim <id> --turns <N>` leaves the agent to invent the number —
and `cmd_claim` (`libexec/tp-task:906-915`) rewrites `turn_budget_remaining` and
zeroes `consecutive_failed_iterations` on **every** call, same-branch re-claims
included — the two counters behind two of `scrub`'s three tripwires
(`:2133-2181`), so the invented number replaces the supervisor's budget and
resets the failure streak. The
container's safety net has already claimed the lead task with `--turns
$TASKPUMP_SAFETY_TURNS` (default 3) and started its heartbeat
(`runners/claude-docker/entrypoint.sh:147`, `:668-669`). So the shipped briefs
tell the agent to check `claimed_by:` first and not re-claim, and to omit
`--turns` when it does claim. Issue #90 tracks the underlying hole.

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
healthy. The incident is written up in `docs/PUMP-MECHANISMS.md` §4.

So the note leads with **don't run `next`**, tells the agent to read the task
file directly, shows it what the dead session already committed, and insists on
one of three endings — finish, split, or block.

Two things in that file are known wrong and are **not** a model to copy:

- `templates/resume-note.md:39-40` says all three endings "release the tasks
  blocked behind this one". Only `complete` does — see the asymmetry above. The
  second half of that sentence, that leaving the claim in place releases
  nothing, is correct and is the whole reason the file exists.
- It offers no `release`, unlike the two briefs, so an agent out of budget on a
  resumed task has only `block` — which parks every dependent. That half of
  issue #64 is still open.
