# RESUME CONTEXT — read this before the kickoff brief below

You are **resuming `{{TASK_ID}}`** on this worktree (`{{BRANCH}}`). A previous
agent session claimed this task, committed real work, and then died without
finishing it. Your job is to carry it to a conclusion.

## Do NOT start by running `next`

`{{TASK_ID}}` is already claimed to this branch, so it is **invisible** to
`next` and `ready` — both surface only `status: open` tasks. Calling
`{{TASK_CLI}} next --phase {{PHASE}}` returns `null`, and reading that as
"frontier drained" is precisely the stall that stranded this task. Read the task
file directly instead:

```
cat {{TASK_FILE}}
```

## Work already committed on this branch

```
{{COMMITS}}
```

## Uncommitted state (`git status --short`, then `git diff --stat`)

```
{{STATUS_SHORT}}
```

```
{{DIFF_STAT}}
```

## How to finish

Re-read the task's Spec, Scope, and Acceptance criteria, work out what the
commits above already satisfy, and do the rest. Then pick exactly one of these
three endings. **All three release the tasks blocked behind this one; leaving it
claimed and unfinished does not** — that is what stalled the pump.

1. **Finish it.** `{{TASK_CLI}} complete {{TASK_ID}} --commits <shas>`, once the
   project's gates are clean:

   ```
   {{BUILD_GATE}}
   ```

2. **Split it.** If part of the work is genuinely done and the remainder needs
   judgement, a decision, or scope you cannot settle alone: `complete` the
   finished portion — stating precisely what you did and did **not** do in the
   completion notes — and file the remainder as a new task with
   `{{TASK_CLI}} create {{PHASE}}.<n> --title "..." --goal "..."`, setting its
   `blockers` if it depends on anything. If only the production wiring is
   outstanding, `complete --defer-wiring "..."` instead.

3. **Block it.** If it truly cannot proceed:
   `{{TASK_CLI}} block {{TASK_ID}} --reason "..."`.

Do not hand-edit task frontmatter; the CLI is its only writer. Commit early and
often — another interruption must not lose your work.

---
