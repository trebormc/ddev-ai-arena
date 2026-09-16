#!/usr/bin/env bash
# Shared helpers for the ai-arena scripts. Sourced, not executed.

# Locate the main environment of a coordinator project.
# Sets: MAIN_ENV (dir), REPO_REL (repo subdirectory name), REPO_DIR, BASE (DDEV name).
# Order: $AI_ARENA_MAIN_ENV, <project>/main, then the legacy <project>/worktree/<x>
# whose repo has .git as a DIRECTORY (worktrees have a .git file).
locate_main_env() { # project_dir
  local project="$1" d
  MAIN_ENV=""
  if [ -n "${AI_ARENA_MAIN_ENV:-}" ]; then
    MAIN_ENV="$AI_ARENA_MAIN_ENV"
  elif [ -d "$project/main/.ddev" ] && repo_subdir "$project/main" 1 >/dev/null; then
    MAIN_ENV="$project/main"
  else
    for d in "$project"/worktree/*/; do
      [ -d "${d}.ddev" ] || continue
      if repo_subdir "${d%/}" 1 >/dev/null; then MAIN_ENV="${d%/}"; break; fi
    done
  fi
  [ -n "$MAIN_ENV" ] || die "no main environment found: expected $project/main/ (or worktree/<x>/) with .ddev/ and a repo whose .git is a directory"
  REPO_REL="$(repo_subdir "$MAIN_ENV" 1)" || die "no repository subdirectory in $MAIN_ENV"
  REPO_DIR="$MAIN_ENV/$REPO_REL"
  BASE=""
  [ -f "$MAIN_ENV/.ddev/config.yaml" ] && BASE="$(sed -nE 's/^name:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/p' "$MAIN_ENV/.ddev/config.yaml" | head -n1 || true)"
  [ -n "$BASE" ] || BASE="$(basename "$MAIN_ENV")"
  [ "$BASE" != "main" ] || BASE="$(basename "$project")"
}

# Name of the first subdirectory holding a git checkout. With "1" as second
# argument, only a .git DIRECTORY qualifies (the main clone).
repo_subdir() { # env_dir [require_git_dir]
  local d
  for d in "$1"/*/; do
    [ -e "${d}.git" ] || continue
    if [ "${2:-0}" = "1" ] && [ ! -d "${d}.git" ]; then continue; fi
    basename "$d"; return 0
  done
  return 1
}

# Remove DDEV-generated state from a copied .ddev directory (regenerated on start).
clean_ddev_state() { # ddev_dir
  local d="$1"
  rm -rf "$d"/.ddev-docker-compose-*.yaml "$d/.global_commands" "$d/.homeadditions" \
         "$d/.dbimageBuild" "$d/.webimageBuild" "$d"/.importdb* "$d/db_snapshots" "$d/.agent-ssh-keys" 2>/dev/null || true
}

# Copy untracked/ignored local dev config from the main repo into a worktree.
copy_local_files() { # src_repo dst_repo [extra_specs ';'-separated]
  local src="$1" dst="$2" extra="${3:-}" rel n=0
  local patterns=('**/settings.local.php' '**/development.services.yml' '**/dev.services.yml'
                  '**/devel-twig.services.yml' '**/services.redis.yml' '**/.claude/settings.local.json'
                  '.claude/settings.local.json')
  if [ -n "$extra" ]; then
    local IFS=';'
    # shellcheck disable=SC2206
    patterns+=($extra)
    unset IFS
  fi
  while IFS= read -r -d '' rel; do
    case "$rel" in vendor/*|*/vendor/*|node_modules/*|*/node_modules/*|*/core/*|*/files/*) continue ;; esac
    [ -e "$dst/$rel" ] && continue
    mkdir -p "$(dirname "$dst/$rel")"
    cp -a "$src/$rel" "$dst/$rel"
    n=$((n + 1))
  done < <(git -C "$src" ls-files --others -z -- "${patterns[@]}" 2>/dev/null)
  log "copied $n local config file(s)"
}

# Newest database dump under <project>/backups/ ("-latest" files first).
newest_backup() { # project_dir
  local b="$1/backups" f
  [ -d "$b" ] || return 1
  shopt -s nullglob
  local latest=("$b"/*-latest.sql "$b"/*-latest.sql.gz "$b"/*-latest.mysql "$b"/*-latest.mysql.gz "$b"/*-latest.tar.gz "$b"/*-latest.tgz "$b"/*-latest.zip)
  local all=("$b"/*.sql "$b"/*.sql.gz "$b"/*.mysql "$b"/*.mysql.gz "$b"/*.tar.gz "$b"/*.tgz "$b"/*.zip)
  shopt -u nullglob
  if [ ${#latest[@]} -gt 0 ]; then f="$(ls -t "${latest[@]}" | head -n1)"
  elif [ ${#all[@]} -gt 0 ]; then f="$(ls -t "${all[@]}" | head -n1)"
  else return 1; fi
  printf '%s\n' "$f"
}
