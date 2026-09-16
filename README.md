[![add-on registry](https://img.shields.io/badge/DDEV-Add--on_Registry-blue)](https://addons.ddev.com)
[![tests](https://github.com/trebormc/ddev-ai-arena/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/trebormc/ddev-ai-arena/actions/workflows/tests.yml?query=branch%3Amain)
[![last commit](https://img.shields.io/github/last-commit/trebormc/ddev-ai-arena)](https://github.com/trebormc/ddev-ai-arena/commits)
[![release](https://img.shields.io/github/v/release/trebormc/ddev-ai-arena)](https://github.com/trebormc/ddev-ai-arena/releases/latest)

# ddev-ai-arena

Run the same Drupal task through several AI candidates at once, each in its own git
worktree with its own DDEV project and database, verify each candidate mechanically,
let a project-manager session judge the results blind, and promote the winner to a
`feature/` branch.

> Part of the [DDEV AI Workspace](https://github.com/trebormc/ddev-ai-workspace).
> The candidates and the project manager are the AI containers installed by
> [ddev-claude-code](https://github.com/trebormc/ddev-claude-code) and
> [ddev-opencode](https://github.com/trebormc/ddev-opencode); this add-on adds the
> host-side orchestration only.

## Why

A single agent gives you one shape. Three candidates on different harnesses and models
give you three shapes plus mechanical evidence (PHPStan, PHPCS, PHPUnit, site
bootstrap) per candidate, so the judge decides on gates and a rubric instead of prose.
With cheap or local models as candidates the token cost is near zero; you trade minutes
and disk for quality. A wins log (`~/.ddev/ai-arena/wins.tsv`) tells you over time
which model and harness earns trust for which kind of task.

## Architecture

Three layers, one listener:

- **Layer 1, the host harness** (Claude Code or OpenCode on your machine) is your only
  point of contact. It drives `ddev ai-arena` verbs, relays questions, and reports.
- **Layer 2, the project-manager session** runs inside the MAIN project's AI container
  (`plan`, `pm`, `judge`). It writes the brief, answers candidates from it, escalates
  only real product decisions, and judges blind.
- **Layer 3, the candidates** run detached inside their own project's AI container,
  read the brief, implement, verify on their own site, and write a report.

Containers never talk to each other. The host executes commands in them and reads
files: `arena/<slug>/manifest.json` is the single source of truth, and every session is
resumable by id, so a question travels up as a report and an answer travels down as a
resumed session. Candidates run detached: closing the host session does not stop them.

```
host: ddev ai-arena ─┬─ plan/pm/judge ──▶ main project AI container (layer 2)
                     ├─ spawn ───────────▶ ../<site>-tmp-<slug>-a  (worktree + DDEV + DB)
                     ├─ run/resume ──────▶ candidate a AI container (layer 3, detached)
                     ├─ wait ────────────▶ arena-run.exit / arena-report.md
                     ├─ gate/collect ────▶ arena/<slug>/candidates/<label>/
                     └─ promote/clean ───▶ feature/<slug>, tmp/* removed
```

## Install

```bash
ddev add-on get trebormc/ddev-ai-arena
ddev restart
ddev ai-arena doctor
```

Then install the host skill so your host harness knows the loop: see
[host/README.md](host/README.md).

## Usage

From the main project directory, in the host harness: "run an arena for: add a handling
fee to the order total, three candidates". Or by hand:

```bash
ddev ai-arena init "Add a handling fee" --candidates claude:opus,claude:sonnet,opencode
ddev ai-arena plan add-a-handling-fee      # PM writes arena/<slug>/brief.md
ddev ai-arena spawn add-a-handling-fee     # worktree + DDEV + DB per candidate
ddev ai-arena run add-a-handling-fee       # detached
ddev ai-arena wait add-a-handling-fee --all
ddev ai-arena gate add-a-handling-fee && ddev ai-arena collect add-a-handling-fee
ddev ai-arena judge add-a-handling-fee     # blind, gates first
ddev ai-arena promote add-a-handling-fee b --env
ddev ai-arena reveal add-a-handling-fee
ddev ai-arena clean add-a-handling-fee
```

| Verb | What it does |
|---|---|
| `doctor` | Checks git, jq, ddev, docker, the layout, the main AI containers, the DB snapshot |
| `init "<task>" [--candidates ...] [--pm harness[:model]]` | Creates `arena/<slug>/manifest.json` |
| `plan <slug>` | PM session runs `code-review` PLAN mode and writes the brief |
| `spawn <slug> [label...]` | Worktree on `tmp/<slug>-<label>`, DDEV project, DB, composer, provisioning |
| `run <slug> [label...]` | Starts candidates detached on the brief |
| `wait <slug> [--all] [--timeout S]` | Blocks until a state change; prints JSON |
| `status <slug> [--json]` | Candidate states, gates, branches |
| `resume <slug> <label> "<msg>"` | Continues a candidate's session (answers, new instructions) |
| `pm <slug> "<msg>"` | Talks to the PM session; prints its parsed verdict |
| `gate <slug> [label...]` | Site bootstrap, PHPStan, PHPCS, PHPUnit on changed custom modules |
| `collect <slug>` | Diffs, reports, gates into `arena/<slug>/candidates/` (no model info) |
| `judge <slug>` | PM judges blind: gates, rubric, conformance, then quality |
| `promote <slug> <label> [--branch] [--env]` | `feature/<slug>` from the winner, optionally its environment |
| `reveal <slug>` | Label → harness/model, appends to the wins log |
| `clean <slug> [--keep label] [--purge]` | Deletes candidate projects, worktrees, `tmp/*` branches |
| `list` | Arenas in this project |

## Layouts

Detected from the DDEV project root:

- **Standard**: the repository is the project root (`.ddev/` inside the repo). The
  candidate's project name is set in an untracked `.ddev/config.arena.yaml`.
- **Environment directory**: the project root holds `.ddev/`, `.beads/`, `CLAUDE.md`
  and the repository in one subdirectory (`docroot: app/web`). The environment is
  copied (minus the repo and arena data), `name:` and pinned ports are stripped, and
  the worktree is created inside it.

Candidates are always sibling directories of the project root. A DDEV snapshot named
`baseline` in the main project (see `AI_ARENA_DB_SNAPSHOT`) is the fastest DB source;
otherwise a file, or one export per arena.

## Protocol with the agents

The AI containers follow the `arena-protocol` skill from
[drupal-ai-agents](https://github.com/trebormc/drupal-ai-agents): brief format,
candidate report (`STATUS` first line), PM verdict trailer (`VERDICT`, `TO`, `WINNER`,
`MESSAGE`), and judging rules. The prompts in `ai-arena/prompts/` carry the minimum
inline so a run degrades gracefully if that skill is missing.

## Guardrails

- Only `tmp/*` branches and `<site>-tmp-*` projects are ever deleted.
- The main project's database is never touched; the export used for candidates is
  written under `arena/<slug>/`.
- No commits, no pushes: the winner is a local branch you review and commit.
- Candidates are told: no Beads, no git writes, only the brief's paths.

## Configuration

`.ddev/.env.ai-arena` (created on install): candidate panel, PM harness/model, cap,
timeout, base ref, DB source, extra local files, provisioning steps, spawn/remove hooks.

## Part of DDEV AI Workspace

This add-on is part of [DDEV AI Workspace](https://github.com/trebormc/ddev-ai-workspace), a modular ecosystem of DDEV add-ons for AI-powered Drupal development.

| Repository | Description | Relationship |
|------------|-------------|--------------|
| [ddev-ai-workspace](https://github.com/trebormc/ddev-ai-workspace) | Meta add-on that installs the full AI development stack with one command. | Workspace |
| [ddev-claude-code](https://github.com/trebormc/ddev-claude-code) | [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI container for interactive development. | Runs candidates and the project manager |
| [ddev-opencode](https://github.com/trebormc/ddev-opencode) | [OpenCode](https://opencode.ai) AI CLI container for interactive development. | Runs candidates and the project manager |
| [ddev-ralph](https://github.com/trebormc/ddev-ralph) | Autonomous AI task orchestrator: one task after another through an AI container. | Sibling: sequential loop instead of parallel candidates |
| [ddev-agents-sync](https://github.com/trebormc/ddev-agents-sync) | Syncs agent repos and resolves model tokens per project. | Per-candidate model overrides go through its `.env.agents` cascade |
| [ddev-beads](https://github.com/trebormc/ddev-beads) | [Beads](https://github.com/steveyegge/beads) git-backed task tracker. | Candidates skip it; the main project keeps the task |
| [ddev-playwright-mcp](https://github.com/trebormc/ddev-playwright-mcp) | Headless Playwright browser. | Candidates verify on their own browser |
| [ddev-ai-ssh](https://github.com/trebormc/ddev-ai-ssh) | SSH access to the web container. | Each candidate environment gets its own keys |
| [drupal-ai-agents](https://github.com/trebormc/drupal-ai-agents) | 11 agents, 17 rules, 38 skills for Drupal development. | Provides the `arena-protocol` skill |

## Disclaimer

This project is an independent initiative by [Robert Menetray](https://menetray.com), sponsored by [DruScan](https://druscan.com). It is not affiliated with Anthropic, OpenCode, Beads, Playwright, Microsoft, or DDEV. AI-generated code may contain errors. Always review the winning branch before merging.

## License

Apache-2.0. See [LICENSE](LICENSE).
