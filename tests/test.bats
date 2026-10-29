#!/usr/bin/env bats

# Bats is a testing framework for Bash
# Documentation https://bats-core.readthedocs.io/en/stable/
# Bats libraries documentation https://github.com/ztombol/bats-docs

# ai-arena is a host package (a skill plus scripts), not a DDEV add-on, so these
# tests run on the host without DDEV or Docker: they exercise the installer, the
# CLI's argument handling and project resolution, and the pure helper functions.
#
# For local tests, install bats-core, bats-assert, bats-file, bats-support
# And run this in the package root directory:
#   bats ./tests/test.bats
# For debugging:
#   bats ./tests/test.bats --show-output-of-passing-tests --verbose-run --print-output-on-failure

setup() {
  set -eu -o pipefail

  export GITHUB_REPO=trebormc/ddev-ai-arena

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export SCRIPTS="$DIR/skills/ai-arena/scripts"
  export TESTDIR="$(mktemp -d)"
  # Isolate everything the installer and the CLI write under HOME.
  export HOME="$TESTDIR/home"
  mkdir -p "$HOME"
  export AI_ARENA_MAIN_ENV=""
}

teardown() {
  [ -n "${TESTDIR:-}" ] && rm -rf "$TESTDIR"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Stub ddev and docker so the CLI's `need` checks pass on a host without them.
stub_tools() {
  mkdir -p "$TESTDIR/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTDIR/bin/ddev"
  # `docker ps` must print nothing (no containers running); anything else succeeds silently.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTDIR/bin/docker"
  chmod +x "$TESTDIR/bin/ddev" "$TESTDIR/bin/docker"
  export PATH="$TESTDIR/bin:$PATH"
}

# A coordinator project with a main environment: <coord>/.ddev + <coord>/main/.ddev + <coord>/main/<repo>/.git (directory).
make_coordinator() { # coord_name main_name repo_name
  local coord="$TESTDIR/coord"
  mkdir -p "$coord/.ddev" "$coord/main/.ddev" "$coord/main/$3/.git"
  printf 'name: %s\ntype: generic\n' "$1" > "$coord/.ddev/config.yaml"
  printf 'name: %s\ntype: drupal\n' "$2" > "$coord/main/.ddev/config.yaml"
  printf '%s' "$coord"
}

# Print the definitions of the named functions from the ai-arena CLI so a test can
# eval them without executing the script's dispatch (one-liners end with "...; }").
cli_functions() { # name...
  local fn
  for fn in "$@"; do
    awk -v fn="$fn" '
      $0 ~ "^"fn"\\(\\)" { p = 1; first = 1 }
      p { print; if ($0 ~ /^}/ || (first && $0 ~ /;[ ]*}[ ]*$/)) exit; first = 0 }
    ' "$SCRIPTS/ai-arena"
  done
}

# Minimal stand-ins for the CLI's logging helpers used by the extracted functions.
cli_env() {
  log()  { printf '==> %s\n' "$*" >&2; }
  warn() { printf 'warning: %s\n' "$*" >&2; }
  die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
}

# ---------------------------------------------------------------------------
# Static checks
# ---------------------------------------------------------------------------

@test "all scripts have valid bash syntax" {
  set -eu -o pipefail
  for f in "$DIR/install.sh" "$SCRIPTS/ai-arena" "$SCRIPTS/lib.sh" "$SCRIPTS/worktree-add" "$SCRIPTS/worktree-remove"; do
    run bash -n "$f"
    assert_success
  done
}

@test "package ships the skill, its scripts and every prompt the CLI uses" {
  set -eu -o pipefail
  assert [ -f "$DIR/skills/ai-arena/SKILL.md" ]
  run head -n 2 "$DIR/skills/ai-arena/SKILL.md"
  assert_line --index 0 "---"
  assert_line --index 1 "name: ai-arena"
  for s in ai-arena worktree-add worktree-remove; do
    assert [ -x "$SCRIPTS/$s" ]
  done
  # Every prompt template referenced by the CLI must exist.
  for p in $(grep -oE 'fill_prompt [a-z-]+\.md|PROMPTS_DIR/[a-z-]+\.md' "$SCRIPTS/ai-arena" | grep -oE '[a-z-]+\.md' | sort -u); do
    assert [ -f "$DIR/skills/ai-arena/prompts/$p" ]
  done
}

# ---------------------------------------------------------------------------
# install.sh
# ---------------------------------------------------------------------------

@test "install.sh --help prints its usage" {
  set -eu -o pipefail
  run "$DIR/install.sh" --help
  assert_success
  assert_output --partial "Usage: ./install.sh"
  assert_output --partial "--opencode"
}

@test "install.sh rejects unknown options" {
  set -eu -o pipefail
  run "$DIR/install.sh" --bogus
  assert_failure
  assert_output --partial "unknown option --bogus"
}

@test "install.sh installs the skill into both harnesses and links the CLI" {
  set -eu -o pipefail
  run "$DIR/install.sh"
  assert_success
  assert_output --partial "installed skill to $HOME/.claude/skills/ai-arena"
  assert_output --partial "installed skill to $HOME/.config/opencode/skills/ai-arena"

  for dest in "$HOME/.claude/skills/ai-arena" "$HOME/.config/opencode/skills/ai-arena"; do
    assert [ -f "$dest/SKILL.md" ]
    assert [ -f "$dest/prompts/candidate.md" ]
    for s in ai-arena worktree-add worktree-remove; do
      assert [ -x "$dest/scripts/$s" ]
    done
  done

  # The CLI links point at the first installed copy (Claude Code's).
  for s in ai-arena worktree-add worktree-remove; do
    assert [ -L "$HOME/.local/bin/$s" ]
    run readlink "$HOME/.local/bin/$s"
    assert_output "$HOME/.claude/skills/ai-arena/scripts/$s"
  done

  # Global defaults are written, fully commented out.
  assert [ -f "$HOME/.ddev/ai-arena/config.env" ]
  run grep -c '^[A-Z]' "$HOME/.ddev/ai-arena/config.env"
  assert_output "0"
  run grep -c '^#AI_ARENA_DEFAULT_CANDIDATES=' "$HOME/.ddev/ai-arena/config.env"
  assert_output "1"
}

@test "install.sh --bin alone links the CLI to the repository scripts" {
  set -eu -o pipefail
  run "$DIR/install.sh" --bin
  assert_success
  assert [ ! -e "$HOME/.claude/skills/ai-arena" ]
  assert [ ! -e "$HOME/.config/opencode/skills/ai-arena" ]
  run readlink "$HOME/.local/bin/ai-arena"
  assert_output "$SCRIPTS/ai-arena"
}

@test "install.sh is idempotent and never overwrites an existing config.env" {
  set -eu -o pipefail
  run "$DIR/install.sh"
  assert_success
  echo "AI_ARENA_MAX_CANDIDATES=5" >> "$HOME/.ddev/ai-arena/config.env"
  run "$DIR/install.sh"
  assert_success
  refute_output --partial "wrote $HOME/.ddev/ai-arena/config.env"
  run grep -c '^AI_ARENA_MAX_CANDIDATES=5$' "$HOME/.ddev/ai-arena/config.env"
  assert_output "1"
}

# ---------------------------------------------------------------------------
# ai-arena CLI: arguments and project resolution (no containers involved)
# ---------------------------------------------------------------------------

@test "ai-arena --help and --version work without ddev or docker on the PATH" {
  set -eu -o pipefail
  run "$SCRIPTS/ai-arena" --help
  assert_success
  assert_output --partial "Usage: ai-arena"
  assert_output --partial "doctor"
  assert_output --partial "review"

  run "$SCRIPTS/ai-arena"
  assert_success
  assert_output --partial "Usage: ai-arena"

  run "$SCRIPTS/ai-arena" --version
  assert_success
  assert_output --regexp '^[0-9]+\.[0-9]+\.[0-9]+$'
}

@test "ai-arena refuses to run outside a coordinator project" {
  set -eu -o pipefail
  stub_tools
  mkdir -p "$TESTDIR/notaproject"
  run "$SCRIPTS/ai-arena" --project "$TESTDIR/notaproject" doctor
  assert_failure
  assert_output --partial "is not a DDEV project"
}

@test "ai-arena rejects an unknown command" {
  set -eu -o pipefail
  stub_tools
  local coord
  coord="$(make_coordinator coord-arena mysite repo)"
  run "$SCRIPTS/ai-arena" --project "$coord" frobnicate
  assert_failure
  assert_output --partial "unknown command 'frobnicate'"
}

@test "ai-arena doctor describes the coordinator layout" {
  set -eu -o pipefail
  stub_tools
  local coord
  coord="$(make_coordinator coord-arena mysite repo)"
  run "$SCRIPTS/ai-arena" --project "$coord" doctor
  assert_success
  assert_output --partial "ok    coordinator: coord-arena at $coord"
  assert_output --partial "ok    main environment: $coord/main (repo repo/, base name mysite)"
  assert_output --partial "candidates: $coord/worktree-tmp/mysite-tmp-*"
  # No containers are running on this host: a warning, not a failure.
  assert_output --partial "warn  claude container not running: ddev-coord-arena-claude-code"
  assert_output --partial "warn  opencode container not running: ddev-coord-arena-opencode"
}

@test "ai-arena doctor fails when the coordinator shares its name with the main environment" {
  set -eu -o pipefail
  stub_tools
  local coord
  coord="$(make_coordinator mysite mysite repo)"
  run "$SCRIPTS/ai-arena" --project "$coord" doctor
  assert_failure
  assert_output --partial "FAIL  coordinator name 'mysite' equals the main environment's name"
}

@test "ai-arena list is empty for a project without arenas" {
  set -eu -o pipefail
  stub_tools
  local coord
  coord="$(make_coordinator coord-arena mysite repo)"
  run "$SCRIPTS/ai-arena" --project "$coord" list
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# lib.sh helpers
# ---------------------------------------------------------------------------

@test "lib.sh: ddev_safe_name lowercases and hyphenates" {
  set -eu -o pipefail
  cli_env; . "$SCRIPTS/lib.sh"
  run ddev_safe_name "Add a Handling_Fee!! (v2)"
  assert_output "add-a-handling-fee-v2"
}

@test "lib.sh: repo_subdir distinguishes a main clone from a worktree" {
  set -eu -o pipefail
  cli_env; . "$SCRIPTS/lib.sh"
  mkdir -p "$TESTDIR/env/a-worktree" "$TESTDIR/env/b-clone/.git"
  printf 'gitdir: /elsewhere\n' > "$TESTDIR/env/a-worktree/.git"
  run repo_subdir "$TESTDIR/env"
  assert_output "a-worktree"
  run repo_subdir "$TESTDIR/env" 1
  assert_output "b-clone"
  mkdir -p "$TESTDIR/empty"
  run repo_subdir "$TESTDIR/empty" 1
  assert_failure
}

@test "lib.sh: locate_main_env prefers <project>/main and derives the base name" {
  set -eu -o pipefail
  cli_env; . "$SCRIPTS/lib.sh"
  local coord
  coord="$(make_coordinator coord-arena mysite web)"
  locate_main_env "$coord"
  assert_equal "$MAIN_ENV" "$coord/main"
  assert_equal "$REPO_REL" "web"
  assert_equal "$REPO_DIR" "$coord/main/web"
  assert_equal "$BASE" "mysite"
}

@test "lib.sh: locate_main_env falls back to the legacy worktree/<x> layout" {
  set -eu -o pipefail
  cli_env; . "$SCRIPTS/lib.sh"
  local coord="$TESTDIR/legacy"
  mkdir -p "$coord/.ddev" "$coord/worktree/site/.ddev" "$coord/worktree/site/web/.git" \
           "$coord/worktree/branch/.ddev" "$coord/worktree/branch/web"
  printf 'name: legacy\n' > "$coord/worktree/site/.ddev/config.yaml"
  printf 'gitdir: /elsewhere\n' > "$coord/worktree/branch/web/.git"
  locate_main_env "$coord"
  assert_equal "$MAIN_ENV" "$coord/worktree/site"
  assert_equal "$BASE" "legacy"
}

@test "lib.sh: locate_main_env honours AI_ARENA_MAIN_ENV and fails without a main environment" {
  set -eu -o pipefail
  cli_env; . "$SCRIPTS/lib.sh"
  mkdir -p "$TESTDIR/custom/.ddev" "$TESTDIR/custom/repo/.git"
  printf 'name: custom\n' > "$TESTDIR/custom/.ddev/config.yaml"
  AI_ARENA_MAIN_ENV="$TESTDIR/custom" locate_main_env "$TESTDIR/anything"
  assert_equal "$MAIN_ENV" "$TESTDIR/custom"
  assert_equal "$BASE" "custom"

  mkdir -p "$TESTDIR/bare/.ddev"
  run bash -c "$(declare -f cli_env); cli_env; . '$SCRIPTS/lib.sh'; locate_main_env '$TESTDIR/bare'"
  assert_failure
  assert_output --partial "no main environment found"
}

@test "lib.sh: newest_backup prefers -latest dumps" {
  set -eu -o pipefail
  cli_env; . "$SCRIPTS/lib.sh"
  mkdir -p "$TESTDIR/p/backups"
  touch -d '2 hours ago' "$TESTDIR/p/backups/old.sql"
  touch -d '1 hour ago' "$TESTDIR/p/backups/db-latest.sql.gz"
  touch "$TESTDIR/p/backups/newest.sql"
  run newest_backup "$TESTDIR/p"
  assert_output "$TESTDIR/p/backups/db-latest.sql.gz"
  rm "$TESTDIR/p/backups/db-latest.sql.gz"
  run newest_backup "$TESTDIR/p"
  assert_output "$TESTDIR/p/backups/newest.sql"
  run newest_backup "$TESTDIR/nobackups"
  assert_failure
}

# ---------------------------------------------------------------------------
# ai-arena CLI: pure helpers (harness commands and output parsing)
# ---------------------------------------------------------------------------

@test "cli: harness_cmd builds non-interactive commands for both harnesses" {
  set -eu -o pipefail
  cli_env
  eval "$(cli_functions harness_user container_for harness_cmd)"

  run harness_cmd opencode "" "" /var/www/html/arena/x/prompt.txt
  assert_output 'opencode run --standalone --format json --auto "$(cat /var/www/html/arena/x/prompt.txt)"'

  run harness_cmd opencode litellm/MODEL_CHEAP ses_123 /p.txt
  assert_output --partial "opencode run --standalone --format json --auto -m litellm/MODEL_CHEAP -s ses_123"

  run harness_cmd claude "" "" /p.txt
  assert_output 'claude -p --output-format json --permission-mode bypassPermissions "$(cat /p.txt)"'

  run harness_cmd claude opus abc /p.txt
  assert_output --partial "--model opus --resume abc"

  run harness_user opencode
  assert_output "opencode"
  run container_for claude mysite
  assert_output "ddev-mysite-claude-code"
}

@test "cli: result_text and session_from_output parse OpenCode 2 JSON events" {
  set -eu -o pipefail
  cli_env
  eval "$(cli_functions session_from_output result_text)"
  cat > "$TESTDIR/oc.json" <<'EOF'
{"type":"step_start","timestamp":1,"sessionID":"ses_abc","part":{"id":"prt_1","sessionID":"ses_abc","messageID":"msg_1","type":"step-start"}}
{"type":"text","timestamp":2,"sessionID":"ses_abc","part":{"id":"prt_2","sessionID":"ses_abc","messageID":"msg_1","type":"text","text":"\n\nVERDICT: approve\nMESSAGE: looks good"}}
EOF
  run session_from_output opencode "$TESTDIR/oc.json"
  assert_output "ses_abc"
  run result_text opencode "$TESTDIR/oc.json"
  assert_line --index 0 "VERDICT: approve"
  assert_line --index 1 "MESSAGE: looks good"
}

@test "cli: result_text and session_from_output parse Claude Code JSON output" {
  set -eu -o pipefail
  cli_env
  eval "$(cli_functions session_from_output result_text)"
  printf '{"type":"result","session_id":"sid-1","result":"All done","total_cost_usd":0.01}\n' > "$TESTDIR/cc.json"
  run session_from_output claude "$TESTDIR/cc.json"
  assert_output "sid-1"
  run result_text claude "$TESTDIR/cc.json"
  assert_output "All done"
}

@test "cli: parse_verdict extracts the PM trailer" {
  set -eu -o pipefail
  cli_env
  eval "$(cli_functions parse_verdict)"
  cat > "$TESTDIR/verdict.md" <<'EOF'
Some reasoning first.
VERDICT: question
TO: alpha
WINNER:
MESSAGE: Which cache tags
should be invalidated?
EOF
  run parse_verdict "$TESTDIR/verdict.md"
  assert_success
  run bash -c "$(declare -f cli_env); cli_env; $(cli_functions parse_verdict); parse_verdict '$TESTDIR/verdict.md' | jq -r '[.verdict, .to, .winner, (.message | gsub(\"\\n\"; \" \"))] | join(\"|\")'"
  assert_output "question|alpha||Which cache tags should be invalidated?"
}

@test "cli: slugify produces short DDEV-safe slugs" {
  set -eu -o pipefail
  cli_env
  eval "$(cli_functions slugify)"
  run slugify "Add a Handling Fee!"
  assert_output "add-a-handling-fee"
  run slugify "A very long task title that keeps going well past the limit"
  assert_success
  assert [ "${#output}" -le 32 ]
  assert_output --regexp '^[a-z0-9]+(-[a-z0-9]+)*$'
}
