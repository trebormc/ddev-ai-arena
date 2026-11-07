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

write_report() { printf 'STATUS: DONE\nFILES:\n%s\nEVIDENCE: x\n' "$1" > "$(dirname "$WT")/arena-report.md"; }

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
