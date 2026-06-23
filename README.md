# claude-onboard

A single, idempotent script that gets someone up and running on **Claude Code** —
installs the CLI, applies a sensible baseline config, and *optionally* wires up
personal memory sync to **their own** private git repo so Claude's saved memory
follows them across machines.

It is intentionally generic: it carries **no one else's** permission allowlist,
project rules, or memory. Each person points memory sync at the repo they choose,
and logs in to their own Anthropic account on first launch.

## What it does

1. Installs **Claude Code** (if missing) and puts it on your `PATH`.
2. Applies a small **baseline config** (dark theme, fullscreen TUI) — *without*
   overwriting any settings you already have.
3. **Optionally** sets up memory sync to a private git repo of your choice
   (auto-pull on session start, auto-commit/push on exit).

## Quick start

**Interactive (recommended)** — lets you choose a memory-sync option when prompted:

```bash
curl -fsSL https://raw.githubusercontent.com/prgwiz/claude-onboard/main/onboard-claude.sh -o onboard-claude.sh
bash onboard-claude.sh
```

**One-liner** — note that `curl | bash` has no terminal to prompt at, so it
**skips memory sync** unless you pass the options as environment variables:

```bash
# install Claude + baseline only (no sync):
curl -fsSL https://raw.githubusercontent.com/prgwiz/claude-onboard/main/onboard-claude.sh | bash

# install AND create a new private memory repo on your GitHub:
curl -fsSL https://raw.githubusercontent.com/prgwiz/claude-onboard/main/onboard-claude.sh | SYNC_MODE=create SYNC_REPO=claude-memory bash

# install AND link a repo you already have:
curl -fsSL https://raw.githubusercontent.com/prgwiz/claude-onboard/main/onboard-claude.sh | SYNC_MODE=existing SYNC_REPO=https://github.com/you/your-memory.git bash

# also install the Harbour (xBase) language rules (opt-in):
curl -fsSL https://raw.githubusercontent.com/prgwiz/claude-onboard/main/onboard-claude.sh | HARBOUR=1 bash
```

After it finishes: run `claude`, log in when prompted, and if you enabled sync,
type `/hooks` once inside Claude so the auto-sync Stop hook goes live.

## Memory sync modes

Memory sync is **off by default** and always tied to **your** repo.

| Mode | How to pick | What it does |
|------|-------------|--------------|
| **skip** | default / `SYNC_MODE=none` | Just Claude Code + baseline config. Good for a single machine. |
| **existing** | `SYNC_MODE=existing SYNC_REPO=<url>` | Clones your existing private repo and wires up sync. |
| **create** | `SYNC_MODE=create SYNC_REPO=<name>` | Runs `gh repo create <name> --private` on your account, seeds it, wires up sync. |

When sync is on, the script clones your repo to `~/claude-sync` (override with
`SYNC_DIR=...`), symlinks Claude's memory directory into it, and installs two
hooks in `~/.claude/settings.local.json`:

- **SessionStart** → `git pull` your latest memory.
- **Stop** → commit and push any memory changes (async).

## Harbour (xBase) projects — optional

If you work on Harbour projects, opt in with `--harbour` (or `HARBOUR=1`, or just
answer **y** at the prompt). It clones
[EricLendvai/harbour-language-for-ai-training](https://github.com/EricLendvai/harbour-language-for-ai-training)
to `~/Sandbox/harbour-ai-rules` (override with `HARBOUR_DIR=...`) and writes a
conventions `CLAUDE.md` beside it, so Claude consults the rulebook and function
allowlist for `.prg` work. It's **off by default** and skipped entirely otherwise.

```bash
bash onboard-claude.sh --harbour
# over curl:  curl -fsSL <raw-url> | HARBOUR=1 bash
```

## What it does *not* do

- It does **not** install anyone else's permission allowlist or project-specific
  `CLAUDE.md` — those belong in each project's own repo. (The Harbour language
  rules above are the one exception, and only when you opt in.)
- It does **not** store or transmit any credentials. Anthropic login is
  interactive; GitHub auth uses your own `gh` session.

## Requirements

- `curl` (to fetch the Claude installer).
- For memory sync only: `git`, `gh` (GitHub CLI), and `jq`. The script installs
  any that are missing via `apt`, `brew`, or `dnf`.

## Notes

- **Idempotent** — safe to re-run; it won't duplicate hooks or clobber existing
  settings, and you can re-run later to add sync if you skipped it.
- The memory symlink is derived from your **home directory**, so it assumes you
  launch `claude` from `~`. Memory accumulated while running inside other project
  directories won't be synced.
- Written to be **bash-3.2 safe**, so it runs on stock macOS as well as Linux.

## License

MIT — do whatever you like with it.
