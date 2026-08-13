# `generic-project` — the generic-consumer smoke fixture

A minimum-size project that uses TaskPump and has nothing to do with Arachne. It
is the standing answer to "what does TaskPump look like in a repository that is
not the one it was extracted from", and it is used three ways:

- **Documentation** — every example in the top-level `README.md` runs against
  this tree, so the quickstart is executable rather than illustrative.
- **CI** — the workflow drives the read-only verbs over it to prove the tools
  work outside Arachne's layout, id grammar, and directory names.
- **By hand** — the fastest way to see the ledger behave without authoring one.

It is deliberately not a git repository. TaskPump commits every mutation to the
repository containing the tasks directory, and a fixture that committed to *this*
repository on every run would be unusable. With no enclosing repository the
mutation still happens on disk and the commit is skipped — which is also the
local-first path a laptop with no remote takes, so exercising it here is a
feature.

## Layout

```
generic-project/
  taskpump.conf     # zero ledger keys: tasks/ and T-ids are the defaults now
  tasks/
    T1.md           # done      — the foundation everything else waits on
    T2.1.md         # open      — blocker done, so this is the frontier
    T2.2.md         # open      — waits on T2.1, which is not done yet
    T3.1.md         # blocked   — an external dependency, with a reason
    T3.2.md         # open      — waits on T3.1, so it cannot start either
  src/
    .gitkeep        # stands in for the code the tasks describe
```

## What it demonstrates

**The default id grammar.** Ids are `T<n>` and `T<n>.<m>` — since the v0.1.0
default flips this is the shipped `TASKPUMP_ID_PATTERN`, so the fixture's conf
no longer sets it. Phase derivation, ordering, and range syntax all work off
the shape, not the letter; a consumer with different ids sets the pattern and
sigil keys.

**The eligibility predicate, and its two counts.** Three tasks are `open`, but
only one is eligible:

| Query | Answer | Because |
|---|---|---|
| `tp task ready --count` | `3` | T2.1, T2.2, T3.2 are `open`. The *drain test*: is there work left? |
| `tp task ready --count-eligible` | `1` | Only T2.1 has all blockers `done`. The *stall test*: what can start now? |
| `tp task next` | `T2.1` | The lowest-ordered eligible task. |

That the two counts differ is the normal case, not a problem — T2.2 and T3.2 are
waiting on things that have not happened yet. The pathological case is
`--count > 0` while `--count-eligible == 0`, which means work remains and nothing
can reach it. See [LEDGER-CONTRACT.md §6](../../../docs/LEDGER-CONTRACT.md#6-the-eligibility-predicate).

**A `blocked` task with a reason.** T3.1 is blocked on an external dependency and
records why in both its frontmatter and its body. It also transitively holds up
T3.2, which is what makes a blocked task expensive and worth writing a real
reason for.

**Quoted goals.** Every `goal:` here is quoted. A goal containing a colon and
left unquoted is not valid YAML, and an unparseable task file is invisible to
every verb — it enters no frontier and produces no diagnostic anywhere. One real
task sat that way for nine weeks. `tp task scrub` is the only thing that reports
it, which is why scrub exits 3 when it finds one.

## Try it

```bash
cd tests/fixtures/generic-project

tp task list                        # everything, with status
tp task ready                       # the eligible frontier: T2.1
tp task ready --count               # 3 — open work remains
tp task ready --count-eligible      # 1 — one task can start now
tp task next --branch feat/t2       # the JSON an agent is handed
tp task resolve --all               # which ledger this invocation picked
tp task scrub                       # integrity sweep; exit 0, nothing invisible
```

All of the above are read-only. To watch the state machine move, work on a copy:

```bash
cp -r tests/fixtures/generic-project /tmp/tp-demo && cd /tmp/tp-demo
tp task claim T2.1 --branch feat/t2 --turns 10
tp task ready --count-eligible      # now 0 — the frontier's one task is claimed
tp task complete T2.1
tp task ready --count-eligible      # 1 again — T2.2 was unblocked by the completion
```

That last pair is the frontier mechanism in three commands: nothing was
rescheduled, requeued, or relaunched. T2.2 became eligible because a predicate
over files changed its answer.
