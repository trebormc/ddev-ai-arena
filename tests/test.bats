#!/usr/bin/env bats

# Bats is a testing framework for Bash
# Documentation https://bats-core.readthedocs.io/en/stable/
# Bats libraries documentation https://github.com/ztombol/bats-docs

# For local tests, install bats-core, bats-assert, bats-file, bats-support
# And run this in the add-on root directory:
#   bats ./tests/test.bats
# To exclude release tests:
#   bats ./tests/test.bats --filter-tags '!release'
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
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p "${HOME}/tmp"
  export TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  # The command needs a git repository at the project root (standard layout).
  git init -q -b main .
  git -c user.email=ci@example.com -c user.name=ci commit -q --allow-empty -m "init"
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site
  assert_success
  run ddev start -y
  assert_success
}

health_checks() {
  run ddev ai-arena --help
  assert_success
  assert_output --partial "ai-arena"

  # doctor reports the layout and the (absent) AI containers without crashing.
  run ddev ai-arena doctor
  assert_output --partial "layout: A"

  # An arena can be initialised with no AI container running.
  run ddev ai-arena init "Health check task" --candidates claude:sonnet,opencode
  assert_success
  assert_file_exist "arena/health-check-task/manifest.json"
  run jq -r '.candidates | length' "arena/health-check-task/manifest.json"
  assert_output "2"
  run jq -r '.candidates[0].branch' "arena/health-check-task/manifest.json"
  assert_output "tmp/health-check-task-a"
  run jq -r '.candidates[1].harness' "arena/health-check-task/manifest.json"
  assert_output "opencode"

  run ddev ai-arena status health-check-task
  assert_success
  assert_output --partial "health-check-task"

  run ddev ai-arena list
  assert_success
  assert_output --partial "health-check-task"

  # The candidate cap is enforced.
  run ddev ai-arena init "Too many" --candidates claude,claude,claude,claude
  assert_failure
  assert_output --partial "too many candidates"

  # Nothing to clean yet: clean is idempotent on an un-spawned arena.
  run ddev ai-arena clean health-check-task
  assert_success
}

teardown() {
  set -eu -o pipefail
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

@test "install from directory" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}
