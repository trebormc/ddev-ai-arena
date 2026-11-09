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
  for f in "$DIR/install.sh" "$SCRIPTS/ai-arena" "$SCRIPTS/lib.sh" "$SCRIPTS/worktree-add" "$SCRIPTS/worktree-remove" "$SCRIPTS/host-skills-sync"; do
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
  for s in ai-arena worktree-add worktree-remove host-skills-sync; do
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
    for s in ai-arena worktree-add worktree-remove host-skills-sync; do
      assert [ -x "$dest/scripts/$s" ]
    done
  done

  # The CLI links point at the first installed copy (Claude Code's).
  for s in ai-arena worktree-add worktree-remove host-skills-sync; do
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

@test "ai-arena init records user-defined approaches per label" {
  set -eu -o pipefail
  stub_tools
  local coord
  coord="$(make_coordinator coord-arena mysite repo)"
  run "$SCRIPTS/ai-arena" --project "$coord" init "Add a handling fee" --candidates opencode,opencode \
    --approach "Field plugin on the order entity" --approach "Order processor adjustment"
  assert_success
  assert_output --partial "mode approaches"
  assert_line --index 0 --partial "a: Field plugin on the order entity; b: Order processor adjustment"
  local m="$coord/arena/add-a-handling-fee/manifest.json"
  assert [ -f "$m" ]
  run jq -r '.mode' "$m"
  assert_output "approaches"
  run jq -r '[.candidates[] | .approach] | join("|")' "$m"
  assert_output "Field plugin on the order entity|Order processor adjustment"
  run cat "$coord/arena/add-a-handling-fee/approach-b.md"
  assert_output "Order processor adjustment"
  # status and reveal show the approach of each label
  run "$SCRIPTS/ai-arena" --project "$coord" status add-a-handling-fee
  assert_success
  assert_output --partial "APPROACH"
  assert_output --partial "Order processor adjustment"
  run "$SCRIPTS/ai-arena" --project "$coord" reveal add-a-handling-fee
  assert_success
  assert_output --partial "mode: approaches"
}

@test "ai-arena init rejects a mismatched number of --approach texts" {
  set -eu -o pipefail
  stub_tools
  local coord
  coord="$(make_coordinator coord-arena mysite repo)"
  run "$SCRIPTS/ai-arena" --project "$coord" init "Add a handling fee" --candidates opencode,opencode --approach "only one"
  assert_failure
  assert_output --partial "one per label"
  assert [ ! -f "$coord/arena/add-a-handling-fee/approach-a.md" ]
}

@test "ai-arena --approaches defers to the PM and run refuses until approaches exist" {
  set -eu -o pipefail
  stub_tools
  local coord
  coord="$(make_coordinator coord-arena mysite repo)"
  run "$SCRIPTS/ai-arena" --project "$coord" init "Third task" --candidates opencode,opencode --approaches
  assert_success
  assert_output --partial "the PM proposes one approach per label"
  run jq -r '.mode + ":" + ([.candidates[] | .approach // "null"] | join(","))' "$coord/arena/third-task/manifest.json"
  assert_output "approaches:null,null"
  echo "brief" > "$coord/arena/third-task/brief.md"
  run "$SCRIPTS/ai-arena" --project "$coord" run third-task
  assert_failure
  assert_output --partial "no approach for label a"
  # A models-mode arena is untouched by the feature.
  run "$SCRIPTS/ai-arena" --project "$coord" init "Plain task" --candidates claude,opencode
  assert_success
  run jq -r '.mode' "$coord/arena/plain-task/manifest.json"
  assert_output "models"
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

# ---------------------------------------------------------------------------
# Rounds, usage and comparison
# ---------------------------------------------------------------------------

@test "cli: run_usage reads Claude Code output, subagents included" {
  set -eu -o pipefail
  cli_env
  eval "$(cli_functions run_usage)"
  cat > "$TESTDIR/run.json" <<'EOF'
{"num_turns":47,"total_cost_usd":4.12,"usage":{"input_tokens":1,"output_tokens":2},
 "modelUsage":{"opus":{"inputTokens":60,"outputTokens":50,"cacheReadInputTokens":100,"cacheCreationInputTokens":10},
               "haiku":{"inputTokens":40,"outputTokens":50,"cacheReadInputTokens":100,"cacheCreationInputTokens":10}}}
EOF
  run run_usage claude "$TESTDIR/run.json"
  assert_success
  assert_output '{"steps":47,"input":100,"output":100,"cache_read":200,"cache_write":20,"cost_usd":4.12}'
}

@test "cli: run_usage reads OpenCode events, counts reasoning as output and keeps cost 0" {
  set -eu -o pipefail
  cli_env
  eval "$(cli_functions run_usage)"
  cat > "$TESTDIR/run.json" <<'EOF'
{"type":"step_start","part":{}}
{"type":"text","part":{"text":"hi"}}
{"type":"step_finish","part":{"cost":0,"tokens":{"input":10,"output":1,"reasoning":2,"cache":{"read":100,"write":0}}}}
{"type":"step_finish","part":{"cost":0,"tokens":{"input":20,"output":3,"reasoning":4,"cache":{"read":200,"write":0}}}}
EOF
  run run_usage opencode "$TESTDIR/run.json"
  assert_success
  assert_output '{"steps":2,"input":30,"output":10,"cache_read":300,"cache_write":0,"cost_usd":0}'
}

@test "cli: run_usage prints null when the run left nothing" {
  set -eu -o pipefail
  cli_env
  eval "$(cli_functions run_usage)"
  : > "$TESTDIR/empty.json"
  run run_usage opencode "$TESTDIR/empty.json"
  assert_output "null"
}

# Loads the manifest helpers against a one-candidate manifest in $ARENA_DIR.
arena_fixture() { # harness
  cli_env
  eval "$(cli_functions mf_get mf_update cand_get cand_set cand_set_json labels run_usage record_round now)"
  export ARENA_DIR="$TESTDIR/arena/x" MANIFEST="$TESTDIR/arena/x/manifest.json" ENV_DIR="$TESTDIR/env"
  mkdir -p "$ARENA_DIR" "$ENV_DIR"
  jq -n --arg d "$ENV_DIR" --arg h "$1" '{candidates:[{label:"a", harness:$h, env_dir:$d, started:"2026-11-04T13:24:26Z", cost_usd:null, duration_s:null}]}' > "$MANIFEST"
}

@test "cli: record_round adds up rounds and ends at the exit file, not at the settle time" {
  set -eu -o pipefail
  arena_fixture opencode
  printf '%s\n' '{"type":"step_finish","part":{"cost":0,"tokens":{"input":5,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}}}' > "$ENV_DIR/arena-run.json"
  echo 1 > "$ENV_DIR/arena-run.exit"
  touch -d "2026-11-04T13:45:26Z" "$ENV_DIR/arena-run.exit"
  record_round a opencode 1 DONE

  cand_set a started "2026-11-04T14:07:00Z"
  touch -d "2026-11-04T14:34:00Z" "$ENV_DIR/arena-run.exit"
  record_round a opencode 0 DONE

  run jq -c '.candidates[0] | {duration_s, cost_usd, n:(.rounds | length), first:.rounds[0].duration_s, second:.rounds[1].duration_s, code:.rounds[0].exit_code, end:.finished}' "$MANIFEST"
  assert_output '{"duration_s":2880,"cost_usd":0,"n":2,"first":1260,"second":1620,"code":"1","end":"2026-11-04T14:34:00Z"}'
  # The raw output of every round survives a later resume.
  assert [ -f "$ARENA_DIR/rounds/a-1.json" ]
  assert [ -f "$ARENA_DIR/rounds/a-2.json" ]
}

@test "cli: auto_continue relaunches a clean exit without a report once per phase" {
  set -eu -o pipefail
  arena_fixture opencode
  eval "$(cli_functions auto_continue)"
  mf_update '.status = "running" | .candidates[0].env_name = "e"'
  : > "$ENV_DIR/arena-run.json"; echo 0 > "$ENV_DIR/arena-run.exit"
  container_for() { echo "ddev-$2-opencode"; }
  container_running() { return 0; }
  launch_candidate() { echo "launched $1 resume=$3" >> "$TESTDIR/launches"; }
  warn() { :; }
  AI_ARENA_AUTO_CONTINUE=1 CONTAINER_ROOT=/var/www/html

  # A failed exit, or no session, is not continued.
  run auto_continue a 1 ses_1
  assert_failure
  run auto_continue a 0 ""
  assert_failure
  # A clean exit with a session is continued once, and the stopped round is recorded.
  auto_continue a 0 ses_1
  run cat "$TESTDIR/launches"
  assert_output "launched a resume=1"
  run jq -c '.candidates[0] | {n:.auto_continues.running, st:.rounds[0].status}' "$MANIFEST"
  assert_output '{"n":1,"st":"STOPPED"}'
  run auto_continue a 0 ses_1
  assert_failure
  # A candidate cut at the deadline is never continued.
  mf_update '.status = "drafting" | .candidates[0].cut = true'
  run auto_continue a 0 ses_1
  assert_failure
}

@test "cli: cost_usd stays null when no round reports a cost" {
  set -eu -o pipefail
  arena_fixture claude
  : > "$ENV_DIR/arena-run.json"
  echo 0 > "$ENV_DIR/arena-run.exit"
  record_round a claude 0 DONE
  run jq -c '.candidates[0].cost_usd' "$MANIFEST"
  assert_output "null"
}

@test "cli: brief_lint flags commands that fail in a candidate container" {
  set -eu -o pipefail
  cli_env
  eval "$(cli_functions brief_lint)"
  cat > "$TESTDIR/brief.md" <<'EOF'
ssh web drush php:eval 'echo strlen("a");'
ssh web drush sqlq "SELECT COUNT(*) FROM node"
ssh web bash -lc 'cd app && npm run build'
Run git status --short and paste it.
Pass state: OK (9 tests, 12 assertions)
ssh web 'drush php:eval "echo strlen(\"a\");"'
ssh web drush php:script - <<'PHP'
ssh web "cd app && npm run build"
No git writes. Pass state: 0 failures.
EOF
  run brief_lint "$TESTDIR/brief.md"
  assert_success
  assert_equal "${#lines[@]}" 5
  assert_line --index 0 --partial "1:ssh web drush php:eval"
  assert_line --index 4 --partial "5:Pass state"

  printf 'ssh web drush cr\n' > "$TESTDIR/clean.md"
  run brief_lint "$TESTDIR/clean.md"
  assert_success
  assert_output ""
}

@test "cli: report_files parses FILES and undeclared_files finds what the report omits" {
  set -eu -o pipefail
  cli_env
  eval "$(cli_functions report_files undeclared_files)"
  REPO_REL=app
  cat > "$TESTDIR/report.md" <<'EOF'
STATUS: DONE
SUMMARY: done
FILES:
- web/modules/custom/x/x.module
app/web/modules/custom/x/README.md
EVIDENCE: output
EOF
  report_files "$TESTDIR/report.md" > "$TESTDIR/declared.txt"
  run cat "$TESTDIR/declared.txt"
  assert_line --index 0 "web/modules/custom/x/x.module"
  assert_line --index 1 "web/modules/custom/x/README.md"

  printf 'web/modules/custom/x/x.module\nweb/tmp/lead-review.sqlite\n' > "$TESTDIR/changed.txt"
  run undeclared_files "$TESTDIR/changed.txt" "$TESTDIR/declared.txt"
  assert_success
  assert_output "web/tmp/lead-review.sqlite"

  : > "$TESTDIR/none.txt"
  run undeclared_files "$TESTDIR/declared.txt" "$TESTDIR/declared.txt"
  assert_output ""
}

patch_for() { # file body
  printf 'diff --git a/%s b/%s\nindex abc..def 100644\n+%s\n' "$1" "$1" "$2"
}

@test "cli: identical_production ignores tests, docs and translations but not code" {
  set -eu -o pipefail
  cli_env
  eval "$(cli_functions production_hash identical_production)"
  export ARENA_DIR="$TESTDIR/arena"
  mkdir -p "$ARENA_DIR/candidates/a" "$ARENA_DIR/candidates/b"
  { patch_for src/A.php code; patch_for tests/src/Kernel/ATest.php one; patch_for README.md one; } > "$ARENA_DIR/candidates/a/diff.patch"
  { patch_for src/A.php code; patch_for tests/src/Kernel/ATest.php two; patch_for translations/x.es.po two; } > "$ARENA_DIR/candidates/b/diff.patch"
  run identical_production
  assert_output "yes"

  patch_for src/A.php other > "$ARENA_DIR/candidates/b/diff.patch"
  run identical_production
  assert_output ""

  # Only tests changed: nothing to compare, so no claim either way.
  patch_for tests/src/Kernel/ATest.php one > "$ARENA_DIR/candidates/a/diff.patch"
  patch_for tests/src/Kernel/ATest.php one > "$ARENA_DIR/candidates/b/diff.patch"
  run identical_production
  assert_output ""
}

@test "cli: phpunit_totals sums both PHPUnit summary formats" {
  set -eu -o pipefail
  cli_env
  eval "$(cli_functions phpunit_totals)"
  mkdir -p "$TESTDIR/g"
  run phpunit_totals "$TESTDIR/g"
  assert_output "null"
  printf 'OK (3 tests, 9 assertions)\n' > "$TESTDIR/g/phpunit-a.log"
  printf 'FAILURES!\nTests: 5, Assertions: 7, Failures: 1, Errors: 2, Deprecations: 3.\n' > "$TESTDIR/g/phpunit-b.log"
  run phpunit_totals "$TESTDIR/g"
  assert_output '{"tests":8,"assertions":16,"failures":1,"errors":2}'
}

# A coordinator with a real repository, a winner branch and its candidate tree.
git_arena() {
  stub_tools
  COORD_DIR="$TESTDIR/coord"
  mkdir -p "$COORD_DIR/.ddev" "$COORD_DIR/main/.ddev" "$COORD_DIR/arena/x/candidates/a" "$COORD_DIR/worktree-tmp"
  printf 'name: base-arena\ntype: generic\n' > "$COORD_DIR/.ddev/config.yaml"
  printf 'name: base\ntype: drupal\n' > "$COORD_DIR/main/.ddev/config.yaml"
  REPO="$COORD_DIR/main/app"; WT="$COORD_DIR/worktree-tmp/base-tmp-x-a/app"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.name t; git -C "$REPO" config user.email t@t
  echo base > "$REPO/file.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m base
  mkdir -p "$(dirname "$WT")"
  git -C "$REPO" worktree add -q -b tmp/x-a "$WT"
  jq -n --arg d "$(dirname "$WT")" '{slug:"x", status:"judged", mode:"models", pm:{harness:"claude"}, candidates:[{label:"a", harness:"claude", branch:"tmp/x-a", env_dir:$d, env_name:"base-tmp-x-a", state:"DONE"}], judge:{winner:"a"}, winner:null}' > "$COORD_DIR/arena/x/manifest.json"
  export HOME_GIT=1
}

write_report() { printf 'STATUS: DONE\nFILES:\n%s\nEVIDENCE: x\nSELF-REVIEW: no findings\n' "$1" > "$(dirname "$WT")/arena-report.md"; }

# Answers like the containers of a phased arena: PM calls write the brief, the graft call its report.
phased_docker() {
  cat > "$TESTDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ps) printf '%s\n' ddev-base-arena-claude-code ddev-base-tmp-x-a-claude-code ddev-base-feature-x-claude-code ;;
  exec)
    printf '%s\n' "$*" >> "$STUB_LOG"
    if [ "$2" = "-d" ]; then
      # A detached reviewer inside an environment finishes at once when STUB_ENVROOT maps its root.
      if [ -n "${STUB_ENVROOT:-}" ]; then
        p="$(grep -o '/var/www/html/arena-review/[^ ;]*-run.exit' <<< "$*" | head -n1)"
        [ -z "$p" ] || { mkdir -p "$(dirname "$STUB_ENVROOT${p#/var/www/html}")"; echo 0 > "$STUB_ENVROOT${p#/var/www/html}"; }
      fi
      exit 0
    fi
    case "$*" in
      *ddev-base-arena-claude-code*) echo contract > "$STUB_BRIEF" ;;
      *) printf 'STATUS: DONE\nFILES:\nfile.txt\nEVIDENCE: x\nSELF-REVIEW: no findings\n' > "$STUB_ENV/arena-report.md" ;;
    esac
    printf '{"type":"result","session_id":"s9","result":"VERDICT: DONE\\nTO: none\\nWINNER: a\\nMESSAGE: ok"}\n' ;;
esac
exit 0
EOF
  chmod +x "$TESTDIR/bin/docker"
  export STUB_LOG="$TESTDIR/docker.log" STUB_BRIEF="$COORD_DIR/arena/x/brief.md"
  local m="$COORD_DIR/arena/x/manifest.json"
  jq '.plan_by = "candidates" | .candidates[0].state = "DONE" | .candidates[0].session = "s1"' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
}

@test "init plans in the candidates by default, approaches keep the PM, and each flow rejects the other's verbs" {
  set -eu -o pipefail
  stub_tools
  local coord
  coord="$(make_coordinator coord-arena mysite repo)"
  run "$SCRIPTS/ai-arena" --project "$coord" init "Staged task"
  assert_success
  run jq -r '.plan_by' "$coord/arena/staged-task/manifest.json"
  assert_output "candidates"
  run "$SCRIPTS/ai-arena" --project "$coord" plan staged-task
  assert_failure
  assert_output --partial "plans in the candidates"
  run "$SCRIPTS/ai-arena" --project "$coord" run staged-task
  assert_failure
  assert_output --partial "ai-arena merge"

  run "$SCRIPTS/ai-arena" --project "$coord" init "Other" --plan-by nobody
  assert_failure
  run "$SCRIPTS/ai-arena" --project "$coord" init "Other" --plan-by candidates --approach "x" --approach "y"
  assert_failure
  assert_output --partial "does not combine"

  run "$SCRIPTS/ai-arena" --project "$coord" init "Two designs" --approach "x" --approach "y"
  assert_success
  run jq -r '.plan_by' "$coord/arena/two-designs/manifest.json"
  assert_output "pm"

  run "$SCRIPTS/ai-arena" --project "$coord" init "Plain task" --plan-by pm
  assert_success
  run "$SCRIPTS/ai-arena" --project "$coord" draft plain-task
  assert_failure
  assert_output --partial "planned by the PM"
}

@test "merge needs a plan, keeps it blind, stores the base plan and run resumes the planner" {
  set -eu -o pipefail
  git_arena
  phased_docker
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" merge x
  assert_failure
  assert_output --partial "no plan to merge"

  echo "my plan" > "$(dirname "$WT")/arena-plan.md"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" merge x
  assert_success
  run cat "$COORD_DIR/arena/x/plans/a.md"
  assert_output "my plan"
  run jq -r '.status + ":" + .plan_verdict.winner' "$COORD_DIR/arena/x/manifest.json"
  assert_output "planned:a"

  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" run x
  assert_success
  run tail -n1 "$STUB_LOG"
  assert_output --partial "s1"
  run cat "$(dirname "$WT")/arena-prompt.txt"
  assert_output --partial "It replaces your plan"
  run cat "$(dirname "$WT")/arena-brief.md"
  assert_output "contract"

  # A harness in AI_ARENA_RUN_FRESH starts a new session and is pointed at its own plan.
  echo 'AI_ARENA_RUN_FRESH=opencode,claude' >> "$COORD_DIR/ai-arena.env"
  local m="$COORD_DIR/arena/x/manifest.json"
  jq '.candidates[0].state = "DONE"' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
  : > "$STUB_LOG"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" run x
  assert_success
  run cat "$STUB_LOG"
  refute_output --partial "s1"
  run cat "$(dirname "$WT")/arena-prompt.txt"
  assert_output --partial "you wrote /var/www/html/arena-plan.md"
  refute_output --partial "It replaces your plan"
}

@test "merge warns when a planner changed files" {
  set -eu -o pipefail
  git_arena
  phased_docker
  echo "my plan" > "$(dirname "$WT")/arena-plan.md"
  echo changed > "$WT/file.txt"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" merge x
  assert_success
  assert_output --partial "changed files while planning"
  refute_output --partial "config change(s)"

  # A planner that wrote config into its database is reported too.
  printf '#!/usr/bin/env bash\ncase "$*" in *config:status*) echo %s ;; esac\nexit 0\n' "'[{\"name\":\"field.storage.node.field_scratch\"}]'" > "$TESTDIR/bin/ddev"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" merge x
  assert_success
  assert_output --partial "candidate a left 1 config change(s) in its database while planning"
}

@test "graft needs a promoted environment, skips an empty list, and gates the final environment" {
  set -eu -o pipefail
  git_arena
  phased_docker
  local m="$COORD_DIR/arena/x/manifest.json" env="$COORD_DIR/worktree/base-feature-x"
  echo "port the cache tag from b" > "$COORD_DIR/arena/x/grafts.md"
  echo contract > "$COORD_DIR/arena/x/brief.md"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" graft x
  assert_failure
  assert_output --partial "no promoted environment"

  mkdir -p "$env/.ddev" "$COORD_DIR/arena/x/candidates/b"
  printf 'name: base-feature-x\ntype: drupal\n' > "$env/.ddev/config.yaml"
  git -C "$REPO" worktree add -q -b feature/x "$env/app"
  echo loser > "$COORD_DIR/arena/x/candidates/b/diff.patch"
  jq --arg d "$env" '.winner = {label:"a", branch:"feature/x", env_dir:$d}
    | .candidates += [{label:"b", harness:"opencode", branch:"tmp/x-b", env_dir:"/none", state:"DONE"}]' "$m" > "$m.tmp" && mv "$m.tmp" "$m"

  echo none > "$COORD_DIR/arena/x/grafts.md"
  : > "$STUB_LOG"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" graft x
  assert_success
  assert_output --partial "nothing to graft"
  run cat "$STUB_LOG"
  assert_output ""

  echo "port the cache tag from b" > "$COORD_DIR/arena/x/grafts.md"
  export STUB_ENV="$env"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" graft x
  assert_success
  assert_file_contents() { run cat "$1"; assert_output "$2"; }
  assert_file_contents "$env/arena-grafts/b.patch" "loser"
  assert_file_contents "$env/arena-grafts/grafts.md" "port the cache tag from b"
  assert [ ! -e "$env/arena-grafts/a.patch" ]
  assert [ -f "$COORD_DIR/arena/x/candidates/final/gates.json" ]
  run jq -r '.status + ":" + .final.state + ":" + .final.session + ":" + ([.candidates[].label] | join(","))' "$m"
  assert_output "grafted:DONE:s9:a,b"

  : > "$STUB_LOG"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" graft x --message "fix this"
  assert_success
  run cat "$STUB_LOG"
  assert_output --partial "s9"
  run cat "$env/arena-graft-prompt.txt"
  assert_output --partial "fix this"
}

@test "cli: grafts_empty accepts blanks and none, not a real list" {
  set -eu -o pipefail
  cli_env
  eval "$(cli_functions grafts_empty)"
  printf '\n  \n' > "$TESTDIR/g"; run grafts_empty "$TESTDIR/g"; assert_success
  printf 'None.\n' > "$TESTDIR/g"; run grafts_empty "$TESTDIR/g"; assert_success
  printf 'none\nport X from b\n' > "$TESTDIR/g"; run grafts_empty "$TESTDIR/g"; assert_failure
}

@test "cli: the first DONE of a phase sets the deadline, later ones and other states do not" {
  set -eu -o pipefail
  arena_fixture claude
  eval "$(cli_functions deadline_note)"
  local m="$MANIFEST"
  jq '.status = "running" | .candidates[0].rounds = [{duration_s:600}] | .candidates += [{label:"b", rounds:[{duration_s:900}]}]' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
  AI_ARENA_DEADLINE_FACTOR=2
  deadline_note a BLOCKED 2>/dev/null
  run jq -c '.deadline' "$m"; assert_output "null"
  deadline_note a DONE 2>/dev/null
  deadline_note b DONE 2>/dev/null
  run jq -c '.deadline' "$m"
  assert_output '{"phase":"running","label":"a","first_s":600,"factor":2,"limit_s":1200}'
  # A new phase gets its own deadline; factor 0 disables it.
  jq '.status = "drafting"' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
  AI_ARENA_DEADLINE_FACTOR=0; deadline_note b DONE 2>/dev/null
  run jq -r '.deadline.phase' "$m"; assert_output "running"
  AI_ARENA_DEADLINE_FACTOR=1.5; deadline_note b DONE 2>/dev/null
  run jq -c '[.deadline.phase, .deadline.limit_s]' "$m"; assert_output '["drafting",1350]'
}

@test "wait stops a candidate past the deadline, marks it cut and the judge is told" {
  set -eu -o pipefail
  git_arena
  phased_docker
  local m="$COORD_DIR/arena/x/manifest.json" benv="$COORD_DIR/worktree-tmp/base-tmp-x-b"
  mkdir -p "$benv" "$COORD_DIR/arena/x/candidates/b"
  jq --arg d "$benv" --arg s "$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)" '.status = "running"
    | .deadline = {phase:"running", label:"a", first_s:600, factor:2, limit_s:1200}
    | .candidates += [{label:"b", harness:"opencode", branch:"tmp/x-b", env_name:"base-tmp-x-b", env_dir:$d, state:"running", started:$s}]' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" wait x --all --interval 1
  assert_success
  assert_output --partial "past the deadline of 1200s"
  run jq -r '.candidates[1] | "\(.state):\(.cut):\(.exit_code)"' "$m"
  assert_output "FAILED:true:143"

  printf 'STATUS: DONE\n' > "$COORD_DIR/arena/x/candidates/a/report.md"
  printf 'STATUS: FAILED\n' > "$COORD_DIR/arena/x/candidates/b/report.md"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" judge x
  assert_success
  run cat $(ls "$COORD_DIR"/arena/x/pm/prompt-*.txt | tail -n1)
  assert_output --partial "STOPPED AT THE DEADLINE: b ran past 2x"
  assert_output --partial "GRAFTS:"
}

@test "cli: cross-reviewers are the other candidates' harnesses, never the author's" {
  set -eu -o pipefail
  arena_fixture claude
  eval "$(cli_functions xreviewers_for)"
  jq '.candidates += [{label:"b", harness:"opencode", model:null}, {label:"c", harness:"claude", model:"sonnet"}]' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
  run xreviewers_for a; assert_output "opencode:"
  run xreviewers_for b; assert_output $'claude:\nclaude:sonnet'
}

@test "a finished implementation gets a fresh self-review and a cross-review inside its own environment" {
  set -eu -o pipefail
  git_arena
  phased_docker
  printf '%s\n' ddev-base-arena-claude-code ddev-base-tmp-x-a-claude-code ddev-base-tmp-x-a-opencode > "$TESTDIR/ps"
  sed -i 's|  ps) printf .*|  ps) cat "$STUB_PS" ;;|' "$TESTDIR/bin/docker"
  export STUB_PS="$TESTDIR/ps"
  local m="$COORD_DIR/arena/x/manifest.json" env; env="$(dirname "$WT")"
  echo changed > "$WT/file.txt"
  write_report file.txt
  echo 0 > "$env/arena-run.exit"
  jq --arg s "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.status = "running" | .candidates[0].state = "running" | .candidates[0].started = $s | .candidates[0].model = "opus"
    | .candidates += [{label:"b", harness:"opencode", branch:"tmp/x-b", env_name:"base-tmp-x-b", env_dir:"/none", state:"FAILED"}]' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
  : > "$STUB_LOG"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" wait x
  assert_success
  run cat "$STUB_LOG"
  assert_output --partial "ddev-base-tmp-x-a-claude-code"
  assert_output --partial "ddev-base-tmp-x-a-opencode"
  refute_output --partial "ddev-base-arena-"
  run jq -c '.candidates[0].reviewers' "$m"
  assert_output '[{"label":"self","harness":"claude","model":"opus"},{"label":"x1","harness":"opencode","model":null}]'
  # Fresh sessions: no --resume of the candidate's own session.
  run grep -c -- '--resume' "$STUB_LOG"
  assert_output "0"
  run cat "$env/arena-review/x1-prompt.txt"
  assert_output --partial "/var/www/html/arena-review/diff.patch"
  assert_output --partial "/var/www/html/app"
  assert_output --partial "runs the site of the code under review"
  run cat "$env/arena-review/intent.txt"
  assert_output --partial "/var/www/html/arena-brief.md"

  for r in self x1; do echo "## Verdict $r" > "$env/arena-review/$r.md"; echo 0 > "$env/arena-review/$r-run.exit"; done
  echo junk > "$WT/probe.txt"
  mkdir -p "$COORD_DIR/arena/x/candidates/b"; printf 'STATUS: FAILED\n' > "$COORD_DIR/arena/x/candidates/b/report.md"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" judge x
  assert_success
  assert_output --partial "a reviewer of a left files in its tree"
  run cat "$COORD_DIR/arena/x/candidates/a/review-x1.md"
  assert_output "## Verdict x1"
  run cat $(ls "$COORD_DIR"/arena/x/pm/prompt-*.txt | tail -n1)
  assert_output --partial "REVIEWS: each candidate reviewed and fixed its own diff"
  refute_output --partial "STOPPED AT THE DEADLINE"
}

@test "review --arena runs the author's harness fresh and the others inside the final environment, and re-reviews the fixes" {
  set -eu -o pipefail
  git_arena
  phased_docker
  printf '%s\n' ddev-base-arena-claude-code > "$TESTDIR/ps"
  sed -i 's|  ps) printf .*|  ps) cat "$STUB_PS" ;;|' "$TESTDIR/bin/docker"
  export STUB_PS="$TESTDIR/ps"
  local m="$COORD_DIR/arena/x/manifest.json" env="$COORD_DIR/worktree/base-feature-x" prev="$COORD_DIR/arena/reviews/review-old"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" review --arena x
  assert_failure
  assert_output --partial "no promoted environment"

  mkdir -p "$env/.ddev" "$prev"; echo "## Act on" > "$prev/verdict.md"; echo old > "$prev/diff.patch"
  printf 'name: base-feature-x\ntype: drupal\n' > "$env/.ddev/config.yaml"
  echo contract > "$COORD_DIR/arena/x/brief.md"
  git -C "$REPO" worktree add -q -b feature/x "$env/app"
  echo changed > "$env/app/file.txt"
  jq --arg d "$env" --arg p "$prev" '.winner = {label:"a", branch:"feature/x", env_dir:$d} | .final = {label:"final", harness:"claude", model:"opus", env_dir:$d}
    | .candidates += [{label:"b", harness:"opencode", model:null, branch:"tmp/x-b", env_dir:"/none", state:"DONE"}]
    | .reviews = [{dir:$p, diff_sha:"old"}]' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" status x
  assert_output --partial "final code: changed since the last review"

  # Environment containers down: the review falls back to the coordinator and says so.
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" review --arena x --reviewers claude --timeout 1
  assert_output --partial "reviewing from the coordinator, without the site"

  printf '%s\n' ddev-base-arena-claude-code ddev-base-feature-x-claude-code ddev-base-feature-x-opencode > "$TESTDIR/ps"
  : > "$STUB_LOG"
  export STUB_ENVROOT="$env"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" review --arena x --timeout 30
  assert_success
  assert_output --partial "reviewers run inside base-feature-x"
  run cat "$STUB_LOG"
  assert_output --partial "ddev-base-feature-x-claude-code"
  assert_output --partial "ddev-base-feature-x-opencode"
  assert_output --partial "--model opus"
  refute_output --partial "--resume"
  local rd; rd="$(ls -d "$env"/arena-review/review-2* | tail -n1)"
  run cat "$rd/intent.txt"
  assert_output --partial "/var/www/html/arena-brief.md"
  assert_output --partial "/var/www/html/arena-review/$(basename "$rd")/previous-verdict.md"
  run cat "$rd/previous-verdict.md"
  assert_output "## Act on"
  run cat "$env/arena-brief.md"
  assert_output "contract"
  # The lead synthesis runs in the coordinator and reads the reviews copied back there.
  local cd; cd="$COORD_DIR/arena/reviews/$(basename "$rd")"
  run cat "$cd/lead-prompt.txt"
  assert_output --partial "/var/www/html/arena/reviews/$(basename "$rd")/r1.md"
  run test -s "$cd/verdict.md"
  assert_success
}

@test "promote refuses files the report does not declare and --allow-undeclared overrides it" {
  set -eu -o pipefail
  git_arena
  echo changed > "$WT/file.txt"; echo junk > "$WT/stray.sqlite"
  write_report file.txt

  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" promote x a
  assert_failure
  assert_output --partial "stray.sqlite"
  run git -C "$REPO" branch --list feature/x
  assert_output ""
  run git -C "$WT" log --oneline
  assert_line --index 0 --partial "base"

  rm "$WT/stray.sqlite"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" promote x a
  assert_success
  run git -C "$REPO" branch --list feature/x
  assert_output --partial "feature/x"

  run git -C "$REPO" branch -D feature/x
  git -C "$WT" reset -q --hard HEAD~1
  echo changed > "$WT/file.txt"; echo junk > "$WT/stray.sqlite"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" promote x a --allow-undeclared
  assert_success
  run git -C "$REPO" show --name-only --format= feature/x
  assert_output --partial "stray.sqlite"
}

@test "clean deletes the winner's tmp branch once the promoted branch contains it" {
  set -eu -o pipefail
  git_arena
  echo changed > "$WT/file.txt"
  write_report file.txt
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" promote x a
  assert_success
  git -C "$REPO" worktree remove --force "$WT"
  rm -rf "$(dirname "$WT")"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" clean x
  assert_success
  run git -C "$REPO" branch --list 'tmp/*'
  assert_output ""
  run git -C "$REPO" branch --list feature/x
  assert_output --partial "feature/x"
}

@test "ai-arena compare prints rounds, totals, tests and failed gates by label" {
  set -eu -o pipefail
  stub_tools
  local coord; coord="$(make_coordinator base-arena base app)"
  mkdir -p "$coord/arena/x/candidates/a/gates" "$coord/arena/x/candidates/b/gates"
  printf 'OK (11 tests, 40 assertions)\n' > "$coord/arena/x/candidates/a/gates/phpunit-m.log"
  patch_for src/A.php same > "$coord/arena/x/candidates/a/diff.patch"
  patch_for src/A.php same > "$coord/arena/x/candidates/b/diff.patch"
  cat > "$coord/arena/x/manifest.json" <<'EOF'
{"slug":"x","status":"collected","candidates":[
 {"label":"a","state":"DONE","cost_usd":4.125,"duration_s":1292,"gates":{"site":"pass","phpunit":"pass"},
  "rounds":[{"round":1,"duration_s":1292,"steps":47,"input":100,"output":50,"cache_read":0,"cache_write":0,"cost_usd":4.125}]},
 {"label":"b","state":"DONE","cost_usd":0,"duration_s":2880,"gates":{"site":"pass","phpunit":"fail"},
  "rounds":[{"round":1,"duration_s":1260,"steps":110,"input":10,"output":1,"cache_read":0,"cache_write":0,"cost_usd":0},
            {"round":2,"duration_s":1620,"steps":114,"input":20,"output":2,"cache_read":0,"cache_write":0,"cost_usd":0}]}]}
EOF
  run "$SCRIPTS/ai-arena" --project "$coord" compare x
  assert_success
  assert_output --partial "note: every candidate delivered the same production code"
  assert_output --regexp "a +1 +0 h 22 min +47 +150 +\\\$4\.13"
  assert_output --regexp "b +2 +0 h 27 min +114 +22 +\\\$0"
  assert_output --regexp "b +total +0 h 48 min +224 +33 +\\\$0"
  assert_output --partial "a: 11 tests, 0 failures, 0 errors; gates: all pass"
  assert_output --partial "b: no test run; gates: failed phpunit"

  run "$SCRIPTS/ai-arena" --project "$coord" compare x --json
  assert_success
  run bash -c "printf '%s' '$output' | jq -r '.identical_production_code'"
  assert_output "true"
}

@test "worktree-remove without a terminal fails loudly and removes nothing" {
  set -eu -o pipefail
  stub_tools
  local coord; coord="$(make_coordinator base-arena base app)"
  git init -q -b main "$coord/main/app.real"
  rm -rf "$coord/main/app"; mv "$coord/main/app.real" "$coord/main/app"
  mkdir -p "$coord/worktree/base-feature-x/.ddev" "$coord/worktree/base-feature-x/app"
  printf 'name: base-feature-x\n' > "$coord/worktree/base-feature-x/.ddev/config.yaml"
  run bash -c "'$SCRIPTS/worktree-remove' --project '$coord' '$coord/worktree/base-feature-x' < /dev/null"
  assert_failure
  assert_output --partial "nothing was removed"
  assert [ -d "$coord/worktree/base-feature-x" ]
}

# ---------------------------------------------------------------------------
# host-skills-sync
# ---------------------------------------------------------------------------

make_skill() { # repo name
  mkdir -p "$1/.claude/skills/$2"
  printf -- '---\nname: %s\n---\n' "$2" > "$1/.claude/skills/$2/SKILL.md"
}

@test "host-skills-sync links repo skills, later repos win, foreign directories stay" {
  set -eu -o pipefail
  mkdir -p "$HOME/.ddev/ai-arena" "$HOME/.claude/skills/mine" "$HOME/.config/opencode"
  make_skill "$TESTDIR/one" dreaming
  make_skill "$TESTDIR/one" shared
  make_skill "$TESTDIR/one" mine
  make_skill "$TESTDIR/one" ai-arena
  make_skill "$TESTDIR/two" shared
  echo "AI_ARENA_HOST_SKILL_REPOS=$TESTDIR/one,$TESTDIR/two" > "$HOME/.ddev/ai-arena/config.env"

  run "$SCRIPTS/host-skills-sync"
  assert_success
  assert_output --partial "exists and is not a link"
  assert_output --partial "ai-arena is installed by install.sh"
  assert [ -f "$HOME/.claude/skills/dreaming/SKILL.md" ]
  assert [ -f "$HOME/.config/opencode/skills/dreaming/SKILL.md" ]
  run readlink "$HOME/.claude/skills/shared"
  assert_output "$TESTDIR/two/.claude/skills/shared"
  assert [ ! -L "$HOME/.claude/skills/mine" ]
  assert [ ! -e "$HOME/.claude/skills/ai-arena" ]

  run "$SCRIPTS/host-skills-sync" --list
  assert_output --partial "dreaming"
}

@test "host-skills-sync unlinks skills that disappear and is a no-op when unconfigured" {
  set -eu -o pipefail
  mkdir -p "$HOME/.ddev/ai-arena" "$HOME/.claude"
  make_skill "$TESTDIR/one" dreaming
  echo "AI_ARENA_HOST_SKILL_REPOS=$TESTDIR/one" > "$HOME/.ddev/ai-arena/config.env"
  "$SCRIPTS/host-skills-sync"
  assert [ -L "$HOME/.claude/skills/dreaming" ]

  rm -rf "$TESTDIR/one/.claude/skills/dreaming"
  run "$SCRIPTS/host-skills-sync"
  assert_success
  assert [ ! -L "$HOME/.claude/skills/dreaming" ]

  rm "$HOME/.ddev/ai-arena/config.env"
  run "$SCRIPTS/host-skills-sync"
  assert_success
}

@test "install.sh links host-skills-sync and runs it" {
  set -eu -o pipefail
  mkdir -p "$HOME/.ddev/ai-arena" "$HOME/.config/opencode"
  make_skill "$TESTDIR/one" dreaming
  echo "AI_ARENA_HOST_SKILL_REPOS=$TESTDIR/one" > "$HOME/.ddev/ai-arena/config.env"
  run "$DIR/install.sh"
  assert_success
  assert [ -L "$HOME/.local/bin/host-skills-sync" ]
  assert [ -L "$HOME/.claude/skills/dreaming" ]
}

@test "the report gate fails on a changed file the report does not list, and on a listed file that is missing" {
  set -eu -o pipefail
  git_arena
  echo changed > "$WT/file.txt"; echo junk > "$WT/stray.sqlite"
  write_report file.txt
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" gate x a
  assert_success
  run jq -r .report "$COORD_DIR/arena/x/candidates/a/gates.json"
  assert_output "fail"
  run cat "$COORD_DIR/arena/x/candidates/a/gates/report.log"
  assert_output --partial "changed in the tree but not in FILES: stray.sqlite"

  rm "$WT/stray.sqlite"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" gate x a
  run jq -r .report "$COORD_DIR/arena/x/candidates/a/gates.json"
  assert_output "pass"

  write_report "$(printf 'file.txt\nghost.txt')"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" gate x a
  run jq -r .report "$COORD_DIR/arena/x/candidates/a/gates.json"
  assert_output "fail"
  run cat "$COORD_DIR/arena/x/candidates/a/gates/report.log"
  assert_output --partial "listed in FILES but absent from the tree: ghost.txt"

  # A deleted file is a change the report may list.
  rm "$WT/file.txt"
  write_report file.txt
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" gate x a
  run jq -r .report "$COORD_DIR/arena/x/candidates/a/gates.json"
  assert_output "pass"

  # A heading with a note still counts, and a note line in FILES is not a path.
  printf 'STATUS: DONE\nFILES:\nfile.txt\n(file.txt is the only change)\nEVIDENCE: x\nSELF-REVIEW (code-review CODE mode):\n1. none\n' > "$(dirname "$WT")/arena-report.md"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" gate x a
  run jq -r .report "$COORD_DIR/arena/x/candidates/a/gates.json"
  assert_output "pass"

  # DONE without the candidate's own review fails.
  printf 'STATUS: DONE\nFILES:\nfile.txt\nEVIDENCE: x\n' > "$(dirname "$WT")/arena-report.md"
  run "$SCRIPTS/ai-arena" --project "$COORD_DIR" gate x a
  run jq -r .report "$COORD_DIR/arena/x/candidates/a/gates.json"
  assert_output "fail"
  run cat "$COORD_DIR/arena/x/candidates/a/gates/report.log"
  assert_output --partial "STATUS DONE without SELF-REVIEW"
}

@test "worktree-remove refuses uncommitted changes before touching DDEV, -f still removes" {
  set -eu -o pipefail
  git_arena
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/ddev.log"\nexit 0\n' "$TESTDIR" > "$TESTDIR/bin/ddev"
  : > "$TESTDIR/ddev.log"
  local env; env="$(dirname "$WT")"
  mkdir -p "$env/.ddev"
  printf 'name: base-tmp-x-a\n' > "$env/.ddev/config.yaml"
  echo changed > "$WT/file.txt"

  run "$SCRIPTS/worktree-remove" --project "$COORD_DIR" -y "$env"
  assert_failure
  assert_output --partial "uncommitted changes"
  assert_output --partial "nothing was removed"
  assert [ -f "$WT/file.txt" ]
  run grep -c "delete" "$TESTDIR/ddev.log"
  assert_output "0"

  run "$SCRIPTS/worktree-remove" --project "$COORD_DIR" -y -f "$env"
  assert_success
  assert [ ! -d "$env" ]
  run grep -c "delete" "$TESTDIR/ddev.log"
  assert_output "1"
}

@test "worktree-remove removes a clean worktree without -f" {
  set -eu -o pipefail
  git_arena
  local env; env="$(dirname "$WT")"
  mkdir -p "$env/.ddev"
  printf 'name: base-tmp-x-a\n' > "$env/.ddev/config.yaml"
  run "$SCRIPTS/worktree-remove" --project "$COORD_DIR" -y "$env"
  assert_success
  assert [ ! -d "$env" ]
}
