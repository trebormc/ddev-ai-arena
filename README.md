[![last commit](https://img.shields.io/github/last-commit/trebormc/ddev-ai-arena)](https://github.com/trebormc/ddev-ai-arena/commits)
[![release](https://img.shields.io/github/v/release/trebormc/ddev-ai-arena)](https://github.com/trebormc/ddev-ai-arena/releases/latest)

# ai-arena

Run the same Drupal task through several AI candidates at once, each in its own git
worktree with its own DDEV project and database, verify each candidate mechanically,
let a project-manager session judge the results blind, and promote the winner to a
`feature/` branch. You talk to one AI harness on your host; it drives everything.

> Part of the [DDEV AI Workspace](https://github.com/trebormc/ddev-ai-workspace).
> This is a **host package** (a skill for your host AI harness plus scripts), not a
> DDEV add-on. The candidates and the project manager run in the AI containers that
> the workspace installs.
>
> Created by [Robert Menetray](https://menetray.com) · Sponsored by [DruScan](https://druscan.com)

## Why

A single agent gives you one shape. Three candidates on different harnesses and models
give you three shapes plus mechanical evidence (PHPStan, PHPCS, PHPUnit, site
bootstrap) per candidate, so the judge decides on gates and a rubric instead of prose.
With cheap or local models as candidates the token cost is near zero; you trade minutes
and disk for quality. A wins log (`~/.ddev/ai-arena/wins.tsv`) tells you over time
which model and harness earns trust for which kind of task.

## The layout

One directory per project, the **coordinator**, holds everything:

```
projects/<project>/
├── .ddev/              coordinator DDEV project: the AI workspace, no Drupal (layer 2)
├── ai-arena.env        optional per-project settings
├── arena/<slug>/       one folder per arena: manifest, brief, PM sessions, collected candidates
├── backups/            database dumps (optional; the newest "-latest" file is used)
├── main/               the main environment: .ddev/ + <repo>/ (the git clone)
├── worktree/           real branch environments, created with worktree-add
└── worktree-tmp/       arena candidates, disposable (layer 3)
```

Three layers, one listener:

- **Layer 1, the host harness** (Claude Code or OpenCode on your machine, opened in the
  coordinator) is your only point of contact. It brings the other layers up, runs the
  `ai-arena` verbs, relays questions, and reports.
- **Layer 2, the coordinator's AI container.** The project-manager session runs there:
  it reads `main/<repo>`, writes the brief, answers candidates, sees every candidate
  live under `worktree-tmp/`, and judges blind from the collected copies. It has no
  Drupal and needs none.
- **Layer 3, the candidates.** Each is a copy of `main/` with a worktree on
  `tmp/<slug>-<label>`, its own DDEV project and database. The candidate runs detached
  in its own AI container, reads the brief, implements, verifies on its own site, and
  writes a report.

Containers never talk to each other. The host executes commands in them and reads
files: `arena/<slug>/manifest.json` is the single source of truth, and every session is
resumable by id, so a question travels up as a report and an answer travels down as a
resumed session. Candidates run detached: closing the host session does not stop them.
Several arenas can run at once; the main environment never sees any of it.

```
host: ai-arena ─┬─ up ─────────────▶ coordinator containers (layer 2)
                ├─ plan/pm/judge ──▶ PM session in the coordinator's AI container
                ├─ spawn ──────────▶ worktree-tmp/<base>-tmp-<slug>-a  (worktree-add --tmp)
                ├─ run/resume ─────▶ candidate a AI container (layer 3, detached)
                ├─ wait ───────────▶ arena-run.exit / arena-report.md
                ├─ gate/collect ───▶ arena/<slug>/candidates/<label>/
                └─ promote/clean ──▶ feature/<slug> (+ worktree/ env), worktree-tmp/ removed
```

## Requirements

**Linux only.** The scripts are developed and tested on Linux and rely on GNU tools and
bash 4.4 or newer: `readlink -f`, `flock`, `iconv`, empty-array expansion, hardlinks
for the snapshot copy. macOS ships bash 3.2 and BSD userland and is not supported; it
may work with Homebrew bash and coreutils but nobody has tested it. Also needed:
`ddev` 1.24.10+, `docker`, `git`, `jq`.

## Install

Once on the host:

```bash
git clone https://github.com/trebormc/ddev-ai-arena.git
cd ddev-ai-arena && ./install.sh     # copies the skill to ~/.claude/skills and ~/.config/opencode/skills, links ai-arena, worktree-add and worktree-remove into ~/.local/bin
```

Once per project, create the coordinator:

```bash
cd projects/<project>
ddev config --project-type=generic --project-name=<base>-arena
ddev add-on get trebormc/ddev-ai-workspace     # AI containers, Playwright, agents pack; no Drupal needed
ddev start
ai-arena doctor
```

The coordinator's name must differ from the main environment's DDEV name (the base for
candidate names); `ai-arena doctor` fails when they collide. Move your main environment to `main/` (or leave it under
`worktree/<base>/`: it is recognised because its repository's `.git` is a directory).

## Usage

Open your host harness in the coordinator and say: "run an arena for: add a handling
fee to the order total, three candidates". Or by hand:

```bash
ai-arena up
ai-arena init "Add a handling fee" --candidates claude:opus,claude:sonnet,opencode
ai-arena plan add-a-handling-fee        # PM writes arena/<slug>/brief.md
ai-arena spawn add-a-handling-fee       # worktree + DDEV + DB per candidate
ai-arena run add-a-handling-fee         # detached
ai-arena wait add-a-handling-fee --all
ai-arena gate add-a-handling-fee && ai-arena collect add-a-handling-fee
ai-arena judge add-a-handling-fee       # blind, gates first
ai-arena promote add-a-handling-fee b --env
ai-arena reveal add-a-handling-fee
ai-arena clean add-a-handling-fee
```

| Verb | What it does |
|---|---|
| `doctor` | Checks git, jq, ddev, docker, the layout, the coordinator's AI containers, the DB snapshot |
| `up` | Starts the coordinator's containers |
| `init "<task>" [--candidates ...] [--pm harness[:model]]` | Creates `arena/<slug>/manifest.json` |
| `plan <slug>` | PM session runs `code-review` PLAN mode over `main/<repo>` and writes the brief |
| `spawn <slug> [label...]` | `worktree-add --tmp` per candidate: worktree, DDEV project, DB, composer, provisioning |
| `run <slug> [label...]` | Starts candidates detached on the brief |
| `wait <slug> [--all] [--timeout S] [--interval S]` | Blocks until a state change (poll every `--interval` seconds, default 15); prints JSON |
| `status <slug> [--json]` | Candidate states, gates, branches |
| `resume <slug> <label> "<msg>"` | Continues a candidate's session (answers, new instructions) |
| `pm <slug> "<msg>"` | Talks to the PM session; prints its parsed verdict |
| `gate <slug> [label...]` | Site bootstrap, config (unexported config changes fail unless the brief says `Config changes: allowed`), PHPStan, PHPCS, PHPUnit on changed custom modules, inside each candidate |
| `collect <slug>` | Diffs, reports, gates into `arena/<slug>/candidates/` (no model info) |
| `judge <slug>` | PM judges blind: gates, rubric, conformance, then quality |
| `promote <slug> <label> [--branch] [--env]` | Records the candidate's working tree as one commit on its `tmp/` branch (candidates never commit), then creates `feature/<slug>` from it; `--env` also creates its environment under `worktree/` |
| `reveal <slug>` | Label → harness/model/agents with cost and duration, appends to the wins log |
| `clean <slug> [--keep label] [--purge]` | Deletes candidates under `worktree-tmp/` and their `tmp/*` branches; refuses when the judge picked a winner that was not promoted yet |
| `list` | Arenas in this project |
| `review (--branch <b> \| --env <dir> \| --patch <file>) [--reviewers a,b] [--intent "..."]` | Multi-model review of one diff: independent reviewers on different harnesses/models in the coordinator's containers, then a lead synthesis (act on / consider / noted / dismissed); no worktrees needed |

### Evaluating a change to the agents pack

A candidate is `harness[:model][@agents]`. The `@agents` part pins the agents repository
that candidate syncs (a branch or tag of the default repo, or a full `url#ref`), so two
candidates with the same model and task differ only in the agents, rules and skills they
load:

```bash
ai-arena init "Add a handling fee" --candidates claude:sonnet@main,claude:sonnet@feature/new-rule
```

The branch must be pushed (the containers clone it). Same gates, same blind judge, and
`reveal` shows which agents version each label ran, with its cost and duration, so the
wins log becomes an evaluation record for the pack itself. `AI_ARENA_AGENTS_REPO` sets
the default repository the short form refers to.

### Multi-model review

The cheapest use of the coordinator: review one diff with several models and let a lead
synthesize. No candidate environments, no database; reviewers read the diff and the
code from the coordinator's mount.

```bash
ai-arena review --branch feature/add-a-handling-fee --reviewers claude:opus,claude:sonnet,opencode
ai-arena review --env worktree/atlas-feature-x --intent "cache the listing per role"
```

Reviews land in `arena/reviews/<id>/` (`diff.patch`, one `rN.md` per reviewer,
`verdict.md`). Reviewers are blind to each other; the lead does not know which model
wrote which review. Default panel: `AI_ARENA_REVIEWERS` in the config.

### Ordinary environments

The same scripts manage normal branch environments:

```bash
worktree-add feature/DREP-123           # worktree/<base>-feature-DREP-123 from main/, DB, provisioning
worktree-add --db latest feature/x      # import the newest backups/ dump instead of the baseline snapshot
worktree-remove feature/DREP-123        # containers, worktree, directory, branch
```

`worktree-add` copies `main/` (minus the repo and arena data), strips `name:` and pinned
ports, creates the worktree (existing, remote-tracking, or new branch), copies untracked
local config (`settings.local.php`, dev services files), starts DDEV, runs `composer
install`, provisions the database (baseline snapshot of `main/`, newest `backups/` dump
sanitised, or an export of `main/`), and runs `drush cr`, `updb`, `cim`, `cim`.

## Protocol with the agents

The AI containers follow the `arena-protocol` skill from
[drupal-ai-agents](https://github.com/trebormc/drupal-ai-agents): brief format,
candidate report (`STATUS` first line), PM verdict trailer (`VERDICT`, `TO`, `WINNER`,
`MESSAGE`), and judging rules. The prompts in `skills/ai-arena/prompts/` carry the
minimum inline so a run degrades gracefully if that skill is missing. From the
coordinator's Playwright, a candidate's site is reachable at `http://ddev-<env_name>-web`.

## Guardrails

- Only `worktree-tmp/` environments and `tmp/*` branches are ever deleted; `main/` is
  never edited or removed, and its database is never touched.
- The judge works from collected copies with no model information; live candidate
  directories are for answering questions only.
- No pushes, and the only commit the tool ever makes is `promote` recording the winner's working tree on its `tmp/` branch (candidates never commit); `feature/<slug>` is a local branch you review, squash or amend, and push yourself.
- Candidates are told: no Beads, no git writes, only the brief's paths.

## Configuration

`~/.ddev/ai-arena/config.env` (all projects, written by `install.sh`) and
`<project>/ai-arena.env` (this project): candidate panel, PM harness and model, cap,
timeout, database mode, base ref, extra local files, `AI_ARENA_MAIN_ENV`. Candidate
models are applied through each environment's `.ddev/.env.agents` (the cascade
`ddev-agents-sync` already honours) plus the harness's `--model` flag.

## Part of DDEV AI Workspace

| Repository | Description | Relationship |
|------------|-------------|--------------|
| [ddev-ai-workspace](https://github.com/trebormc/ddev-ai-workspace) | Meta add-on that installs the full AI development stack with one command. | Installed in the coordinator and in every environment |
| [ddev-claude-code](https://github.com/trebormc/ddev-claude-code) | [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI container. | Runs candidates and the project manager |
| [ddev-opencode](https://github.com/trebormc/ddev-opencode) | [OpenCode](https://opencode.ai) AI CLI container. | Runs candidates and the project manager |
| [ddev-ralph](https://github.com/trebormc/ddev-ralph) | Autonomous AI task orchestrator: one task after another through an AI container. | Sibling: sequential loop instead of parallel candidates |
| [ddev-agents-sync](https://github.com/trebormc/ddev-agents-sync) | Syncs agent repos and resolves model tokens per project. | Per-candidate model overrides go through its `.env.agents` cascade |
| [ddev-beads](https://github.com/trebormc/ddev-beads) | [Beads](https://github.com/steveyegge/beads) git-backed task tracker. | Candidates skip it; the main environment keeps the task |
| [ddev-playwright-mcp](https://github.com/trebormc/ddev-playwright-mcp) | Headless Playwright browser. | Candidates verify on their own browser; the coordinator can open their sites |
| [ddev-ai-ssh](https://github.com/trebormc/ddev-ai-ssh) | SSH access to the web container. | Each environment gets its own keys |
| [drupal-ai-agents](https://github.com/trebormc/drupal-ai-agents) | 11 agents, 15 rules, 39 skills for Drupal development. | Provides the `arena-protocol` skill |

## Disclaimer

This project is an independent initiative by [Robert Menetray](https://menetray.com), sponsored by [DruScan](https://druscan.com). It is not affiliated with Anthropic, OpenCode, Beads, Playwright, Microsoft, or DDEV. AI-generated code may contain errors. Always review the winning branch before merging.

## License

Apache-2.0. See [LICENSE](LICENSE).
