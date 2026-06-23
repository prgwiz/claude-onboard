#!/usr/bin/env bash
#
# onboard-claude.sh — generic Claude Code setup for a new user or machine.
#
# What it does:
#   1. Installs Claude Code (if missing) and puts it on PATH.
#   2. Applies a small baseline config (dark theme, fullscreen TUI) WITHOUT
#      clobbering any settings you already have.
#   3. OPTIONALLY wires up personal memory sync to YOUR OWN private git repo,
#      so Claude's saved memory follows you across machines. You bring the repo
#      (or let the script create one under your GitHub account).
#
# Nothing here is tied to anyone else's account: memory sync points at the repo
# YOU choose, and Anthropic login happens interactively on first `claude` launch.
# Intentionally NOT included: anyone else's permission allowlist or
# project-specific CLAUDE.md / language rules (those live in each project repo).
#
# Idempotent: safe to re-run.
#
# Non-interactive use (provisioning / scripted):
#   SYNC_MODE=none                                              ./onboard-claude.sh
#   SYNC_MODE=create   SYNC_REPO=claude-memory                  ./onboard-claude.sh
#   SYNC_MODE=existing SYNC_REPO=https://github.com/me/mem.git  ./onboard-claude.sh

set -euo pipefail

log()  { printf '\033[1m[setup]\033[0m %s\n' "$*"; }
warn() { printf '[warn]  %s\n' "$*" >&2; }
die()  { printf '[fail]  %s\n' "$*" >&2; exit 1; }
lc()   { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }   # bash-3.2 safe (macOS)

CLAUDE_DIR="$HOME/.claude"
SYNC_DIR="${SYNC_DIR:-$HOME/claude-sync}"
SYNC_MODE="${SYNC_MODE:-}"     # none | existing | create   (prompted if unset)
SYNC_REPO="${SYNC_REPO:-}"     # git URL, or owner/name, or bare name (create mode)

pkg_install() {
  local missing=()
  for p in "$@"; do command -v "$p" >/dev/null 2>&1 || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  log "installing: ${missing[*]}"
  if   command -v apt-get >/dev/null 2>&1; then sudo apt-get update -qq && sudo apt-get install -y "${missing[@]}"
  elif command -v brew    >/dev/null 2>&1; then brew install "${missing[@]}"
  elif command -v dnf     >/dev/null 2>&1; then sudo dnf install -y "${missing[@]}"
  else die "install these manually, then re-run: ${missing[*]}"; fi
}

#--- 1. Claude Code -----------------------------------------------------------
if ! command -v claude >/dev/null 2>&1; then
  log "installing Claude Code..."
  curl -fsSL https://claude.ai/install.sh | bash
fi
export PATH="$HOME/.local/bin:$PATH"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
for rc in ~/.bashrc ~/.zshrc; do
  [ -f "$rc" ] && ! grep -qxF "$PATH_LINE" "$rc" && echo "$PATH_LINE" >> "$rc" && log "added ~/.local/bin to PATH in $rc"
done
log "claude: $(claude --version 2>/dev/null || echo 'installed — open a new shell if not yet on PATH')"

#--- 2. baseline settings (non-destructive) -----------------------------------
mkdir -p "$CLAUDE_DIR"
SETTINGS="$CLAUDE_DIR/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
if command -v jq >/dev/null 2>&1; then
  tmp=$(mktemp)
  jq 'if has("theme") then . else .theme = "dark" end
      | if has("tui") then . else .tui = "fullscreen" end' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  log "baseline settings applied (existing values left untouched)"
else
  warn "jq not installed — skipping theme defaults (cosmetic only)"
fi

#--- 3. optional memory sync to YOUR OWN repo ---------------------------------
if [ -z "$SYNC_MODE" ]; then
  if [ -t 0 ]; then
    cat <<'EOF'

Memory sync keeps Claude's saved memory in a private git repo so it follows you
across machines. It is entirely optional and tied to YOUR repo. Pick one:
  [s] skip       no sync (you can re-run this script later to add it)
  [e] existing   link a private repo you already have
  [c] create     make a new private repo on your GitHub account
EOF
    read -rp "Choice [s/e/c]: " ans
    case "$(lc "$ans")" in e*) SYNC_MODE=existing ;; c*) SYNC_MODE=create ;; *) SYNC_MODE=none ;; esac
  else
    SYNC_MODE=none
  fi
fi

setup_git_identity() {  # needed so the Stop hook's auto-commits have an author
  local email user
  email=$(git config --global user.email 2>/dev/null || true)
  case "$email" in *@*) return 0 ;; esac
  user=$(gh api user --jq .login 2>/dev/null || echo "")
  [ -z "$user" ] && die "couldn't read your GitHub login — run 'gh auth login' and retry"
  email=$(gh api user --jq '.email // empty' 2>/dev/null || true)
  case "$email" in *@*) ;; *) email="${user}@users.noreply.github.com" ;; esac
  git config --global user.name  "$user"
  git config --global user.email "$email"
  log "git identity set: $user <$email>"
}

if [ "$SYNC_MODE" != "none" ]; then
  pkg_install git curl gh jq
  gh auth status >/dev/null 2>&1 || { log "logging in to GitHub..."; gh auth login; }
  setup_git_identity

  if [ "$SYNC_MODE" = "create" ]; then
    repo_name="${SYNC_REPO:-claude-memory}"
    owner=$(gh api user --jq .login)
    if gh repo view "$owner/$repo_name" >/dev/null 2>&1; then
      log "repo $owner/$repo_name already exists — using it"
    else
      log "creating private repo $owner/$repo_name..."
      gh repo create "$repo_name" --private --description "Personal Claude Code memory sync"
    fi
    SYNC_REPO="$owner/$repo_name"
  fi
  [ -z "$SYNC_REPO" ] && die "SYNC_REPO not set — pass a repo URL or owner/name"

  if [ -d "$SYNC_DIR/.git" ]; then
    log "updating existing sync clone at $SYNC_DIR..."
    git -C "$SYNC_DIR" pull --ff-only || warn "pull failed (continuing)"
  else
    log "cloning $SYNC_REPO into $SYNC_DIR..."
    gh repo clone "$SYNC_REPO" "$SYNC_DIR"
  fi

  # seed memory/ on a brand-new repo so the symlink target exists
  if [ ! -e "$SYNC_DIR/memory/MEMORY.md" ]; then
    mkdir -p "$SYNC_DIR/memory"
    printf '%s\n' "<!-- Claude Code memory index — one line per memory file. -->" \
      > "$SYNC_DIR/memory/MEMORY.md"
    ( cd "$SYNC_DIR" && git add -A && git commit -q -m "Seed memory/" && git push -q ) \
      || warn "initial push failed — push manually later"
  fi

  # symlink Claude's per-project memory dir -> the synced repo
  # (slug is derived from your home dir; assumes you run `claude` from ~)
  PROJECT_SLUG=$(printf '%s' "$HOME" | tr / -)
  PROJECT_DIR="$CLAUDE_DIR/projects/$PROJECT_SLUG"
  MEM_LINK="$PROJECT_DIR/memory"
  mkdir -p "$PROJECT_DIR"
  if   [ -L "$MEM_LINK" ]; then :
  elif [ -e "$MEM_LINK" ]; then mv "$MEM_LINK" "${MEM_LINK}.pre-sync-backup"; ln -s "$SYNC_DIR/memory" "$MEM_LINK"
  else                          ln -s "$SYNC_DIR/memory" "$MEM_LINK"
  fi
  log "memory linked: $MEM_LINK -> $SYNC_DIR/memory"

  # auto-sync hooks (idempotent: strip any prior claude-sync hooks, then add)
  LOCAL="$CLAUDE_DIR/settings.local.json"
  [ -f "$LOCAL" ] || echo '{}' > "$LOCAL"
  START_CMD="{ cd $SYNC_DIR && git pull --ff-only -q; } 2>>$CLAUDE_DIR/claude-sync.log"
  STOP_CMD="{ cd $SYNC_DIR && if [ -n \"\$(git status --porcelain)\" ]; then git add -A && git commit -q -m \"auto-sync \$(date -Iseconds)\" && git push -q; fi; } 2>>$CLAUDE_DIR/claude-sync.log"
  tmp=$(mktemp)
  jq --arg s "$START_CMD" --arg t "$STOP_CMD" '
    def strip: map(select(any(.hooks[]?; (.command // "") | contains("claude-sync")) | not));
    .hooks.SessionStart = ((.hooks.SessionStart // []) | strip)
        + [ { hooks: [ { type: "command", command: $s, timeout: 20 } ] } ]
    | .hooks.Stop        = ((.hooks.Stop        // []) | strip)
        + [ { hooks: [ { type: "command", command: $t, async: true, timeout: 30 } ] } ]
  ' "$LOCAL" > "$tmp" && mv "$tmp" "$LOCAL"
  log "auto-sync hooks installed (pull on session start, commit+push on stop)"
fi

#--- done ---------------------------------------------------------------------
cat <<EOF

[ok] Setup complete.

Next:
  1. Run:  claude       (first launch prompts you to log in to your Anthropic account)
EOF
[ "$SYNC_MODE" != "none" ] && cat <<EOF
  2. Inside Claude:  /hooks       (reloads config so the auto-sync Stop hook goes live)
  3. Memory now syncs to: $SYNC_REPO
     If pushes don't happen on exit, check ~/.claude/claude-sync.log
EOF
exit 0
