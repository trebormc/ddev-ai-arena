#!/usr/bin/env bash
# Install the ai-arena skill (with its scripts and prompts) into the host AI harnesses.
#
# Usage: ./install.sh [--claude] [--opencode] [--bin]
#   no flags     install into Claude Code and OpenCode and link the CLI (all three)
#   --claude     ~/.claude/skills/ai-arena/
#   --opencode   ~/.config/opencode/skills/ai-arena/
#   --bin        ~/.local/bin/ai-arena -> the installed CLI
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skills/ai-arena"
do_claude=0; do_opencode=0; do_bin=0
if [ $# -eq 0 ]; then do_claude=1; do_opencode=1; do_bin=1; fi
for a in "$@"; do
  case "$a" in
    --claude) do_claude=1 ;; --opencode) do_opencode=1 ;; --bin) do_bin=1 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $a" >&2; exit 1 ;;
  esac
done

install_to() { # dest
  mkdir -p "$1"
  cp -a "$SRC"/. "$1"/
  chmod +x "$1"/scripts/ai-arena "$1"/scripts/worktree-add "$1"/scripts/worktree-remove
  echo "installed skill to $1"
}

first=""
[ "$do_claude" = "1" ] && { install_to "$HOME/.claude/skills/ai-arena"; first="${first:-$HOME/.claude/skills/ai-arena}"; }
[ "$do_opencode" = "1" ] && { install_to "$HOME/.config/opencode/skills/ai-arena"; first="${first:-$HOME/.config/opencode/skills/ai-arena}"; }

if [ "$do_bin" = "1" ]; then
  mkdir -p "$HOME/.local/bin"
  for tool in ai-arena worktree-add worktree-remove; do
    target="${first:-$SRC}/scripts/$tool"
    ln -sfn "$target" "$HOME/.local/bin/$tool"
    echo "linked $HOME/.local/bin/$tool -> $target"
  done
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "note: add $HOME/.local/bin to your PATH" ;; esac
fi

mkdir -p "$HOME/.ddev/ai-arena"
if [ ! -f "$HOME/.ddev/ai-arena/config.env" ]; then
  cat > "$HOME/.ddev/ai-arena/config.env" <<'EOF'
# ai-arena defaults for every coordinator project on this host.
# A <project>/ai-arena.env overrides these per project. Every line is optional.

# Candidate panel: comma-separated "harness[:model]" (harness = claude | opencode).
#AI_ARENA_DEFAULT_CANDIDATES=claude:opus,claude:sonnet,opencode

# Project-manager session (runs in the coordinator's AI container).
#AI_ARENA_PM_HARNESS=claude
#AI_ARENA_PM_MODEL=

# Hard cap on candidates per arena; each one is a full copy of the main environment.
#AI_ARENA_MAX_CANDIDATES=3

# Seconds `ai-arena wait` blocks before giving up (0 = forever).
#AI_ARENA_TIMEOUT=7200

# Database for new environments: auto (snapshot, then newest backups/ dump, then an
# export of main), snapshot, latest, file:<path>, export, none.
#AI_ARENA_DB=auto

# Start point for new tmp/ branches (default: HEAD of the main repository).
#AI_ARENA_BASE_REF=

# Extra untracked files to copy from the main repo into each environment (';'-separated git pathspecs).
#AI_ARENA_LOCAL_FILES=

# Main environment when it is not <project>/main or <project>/worktree/<x>.
#AI_ARENA_MAIN_ENV=
EOF
  echo "wrote $HOME/.ddev/ai-arena/config.env (defaults, all commented)"
fi

echo "done. Open your host harness in a coordinator project and run: ai-arena doctor"
