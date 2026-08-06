# TaskPump

TaskPump is a task DAG and an agent supervisor for long-running autonomous work.
Tasks are plain markdown files with YAML frontmatter — one file per task, holding
its status, its blockers, its goal, and its claim — and a single CLI is the only
reader and writer of that state, so claims are atomic and nothing is ever
hand-edited into an inconsistent shape. On top of that ledger sits a pump: a
supervisor that recomputes the eligible frontier every tick, launches sandboxed
agents against it, and keeps going for days. It governs itself against your
plan's usage meter, pauses feeding rather than exhausting your quota, resumes
work stalled behind an abandoned claim, and exits loudly on a genuine deadlock
instead of idling green.

It was extracted from [Arachne](https://github.com/tjmisko/Arachne), where it
drove multi-day unattended phase drains, and is being generalized into a
standalone tool. Full documentation is forthcoming; for now the layout is:

| Path | What lives there |
|------|------------------|
| `bin/tp` | the single entry point — `tp task`, `tp pump`, `tp monitor`, … |
| `libexec/` | the tools themselves (`tp-task`, `tp-pump`, `tp-monitor`, …) |
| `lib/` | sourced shared code: the config core, pump helpers, the DAG layout engine |
| `gates/` | feed gates the pump consults before launching (currently Claude usage) |
| `runners/` | agent launchers; `claude-docker/` is the sandboxed container runner |
| `systemd/` | unit templates for running a pump across days |
| `tests/` | the shell suites; `tests/run-all.sh` runs every one |
| `docs/design/` | design notes |

Configuration is a `taskpump.conf` at the root of the repo you are driving,
discovered by walking up from your current directory to the enclosing git
worktree — never from where the tools are installed, so worktrees never write to
each other's ledgers. See `taskpump.conf.example` for the full key surface.
Environment variables beat the config file, which beats the defaults baked into
each tool; the legacy `ARACHNE_*` spellings are honored throughout the
transition.
