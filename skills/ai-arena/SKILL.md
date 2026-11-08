---
name: ai-arena
description: >-
  Drives an ai-arena run from the HOST harness, in a coordinator project directory:
  N AI candidates implement the same Drupal task in parallel, each in its own git
  worktree with its own DDEV project and database under worktree-tmp/ (layer 3); a
  project-manager session in the coordinator's AI container writes the brief, answers
  their questions and judges the collected diffs blind (layer 2); the winner becomes a
  feature/<slug> branch and, if asked, an environment under worktree/. You are layer 1,
  the user's only point of contact: you start the layers, run the verbs, relay
  questions upward only when a human must decide, and report the result. Also owns
  the worktree-add and worktree-remove scripts for ordinary branch environments.
  Examples:
  - user: "lanza una arena para añadir la tasa de gestión al total, tres candidatos" -> up, init, spawn, draft, merge, run, wait loop, judge, promote --env, graft, review --arena, reveal, clean
  - user: "arena this task with claude:opus and opencode" -> same with --candidates
  - user: "¿cómo va la arena?" -> ai-arena status, summarise
  - user: "crea un entorno para la rama feature/DREP-123" -> worktree-add feature/DREP-123
  - user: "elimina el entorno de la rama feature/DREP-123" -> worktree-remove feature/DREP-123
  - user: "revisa la rama feature/x con varios modelos" -> ai-arena review --branch feature/x
  Never use for tasks that fit in one file or one command (run them directly), and
  never create, start, or delete DDEV projects, worktrees, or branches by hand: only
  through the scripts of this skill.
allowed-tools: Bash Read Glob Grep
---

# ai-arena (host driver, layer 1)

You run on the host, inside a COORDINATOR project directory:

```
<project>/            ← run every command from here
├── .ddev/            coordinator DDEV project: AI containers (Claude Code, OpenCode,
│                     Playwright, agents) and no Drupal
├── arena/<slug>/     one folder per arena (manifest.json is the source of truth)
├── main/             the main environment (.ddev/ + <repo>/). You never edit it
├── worktree/         real branch environments, created with worktree-add
└── worktree-tmp/     arena candidates, disposable, created and removed by the arena
```

The coordinator must be created (`ddev config`) while no DDEV project is registered
under its directory: DDEV refuses a new config above a registered project, but once the
coordinator's `.ddev/config.yaml` exists the nested environments start normally (see the
README). The scripts run on Linux only (GNU tools, bash 4.4+); `doctor` says so on other platforms. They live next to this file in `scripts/` (`ai-arena`, `worktree-add`,
`worktree-remove`); `ai-arena` is also on the PATH after `install.sh`. The user talks
only to you; layers 2 and 3 never talk to the user.

Everything mechanical is a verb of `ai-arena`; everything that needs Drupal judgment
happens inside AI containers through `plan`, `pm`, and `judge`. You decide which verb
comes next and read JSON. `ai-arena status <slug> --json` is the source of truth.

## The run

By default an arena runs in phases: every candidate plans, the PM merges the plans into one
brief, every candidate implements it and reviews and fixes its own diff, then each
implementation gets two more reviews in its own running site (a fresh session of its own
harness and the other harnesses), the judge picks the winner and lists what to port and fix,
the winner's harness does it in a real environment, and the same double review runs there
until nothing is left to act on. Arenas made with
`--plan-by pm` or in approaches mode keep the single PM plan (see the end of this section).

1. **Bring up layer 2.** `ai-arena doctor`, then `ai-arena up` if the coordinator's
   containers are not running. Fix or report what doctor flags.
2. **Init.** `ai-arena init "<task in the user's words>" [--candidates claude,opencode] [--description "..."]`.
   Prints the slug. To evaluate a change to the agents pack, pin the agents repo per
   candidate with `@<branch>` (same model, same task: `claude:sonnet@main,claude:sonnet@feature/x`). Default panel and cap (max 3) come from `ai-arena.env`. Different
   harnesses per label are the point: the cross review needs at least two, so keep the panel
   diverse unless the user names one.
3. **Bring up layer 3.** `ai-arena spawn <slug>`. For each candidate, `worktree-add
   --tmp` copies the main environment, creates the worktree on `tmp/<slug>-<label>`,
   starts its DDEV project `<base>-tmp-<slug>-<label>`, provisions the database
   (baseline snapshot, newest `backups/` dump, or an export of main) and runs composer
   and drush. Minutes per candidate; run it in the background and keep the user
   informed. A failed spawn for one label is not fatal: report it, continue.
4. **Plan.** `ai-arena draft <slug>`, then the wait loop (step 7) until no planner is
   `running`. Each candidate investigates its own copy and writes a plan; it changes
   nothing. A `BLOCKED` planner has no PM behind it yet: put its question to the user and
   `resume` it.
5. **Merge.** `ai-arena merge <slug>`, in the background (it can take 20 minutes). The PM
   picks one plan blind, improves it with the others and writes `arena/<slug>/brief.md`.
   Read the brief. It must fix outcomes, interfaces and tests, not implementation bodies; a
   contract that dictates the code makes every candidate deliver the same thing, so send it
   back with `ai-arena pm`. Do the same with any line `merge` warns about: those commands
   fail in the candidates' containers. On `VERDICT: ASK_USER`, put the question to the user,
   then `ai-arena pm <slug> "<answer>"` and ask it to write the brief.
6. **Run.** `ai-arena run <slug>`: each candidate continues its planning session on the
   merged brief, except harnesses listed in `AI_ARENA_RUN_FRESH` (default `opencode`): they
   start a fresh session that reads their own plan file, because a planning context near its
   limit makes OpenCode compact early and can end the run with `compaction.failed`. Detached; candidates keep working even if this session ends.
7. **Wait loop.** `ai-arena wait <slug>` blocks until any candidate changes state
   (`--all` for all; no timeout unless `--timeout S`). Run it in the background and react:
   - `DONE` → keep waiting for the rest. The first `DONE` of a phase sets the **deadline**:
     every other candidate gets `AI_ARENA_DEADLINE_FACTOR` (default 2) times that time from
     its own start, and `wait` stops it after that. A stopped candidate is marked `cut`;
     its work so far is still collected, and the judge reads it for grafts (it cannot win).
     Tell the user when a candidate is cut.
   - In the implementation phase each candidate has already reviewed and fixed its own diff
     (its report must carry `SELF-REVIEW`, or the `report` gate fails). Each `DONE` or
     `PARTIAL` one then gets **two reviews at once, inside its own environment with its site
     and database**: `self`, a fresh session of its own harness and model, and `x1`..., the
     other candidates' harnesses. They run while the slower candidates keep working; their
     files are under `worktree-tmp/<env_name>/arena-review/`. Nothing to do: `judge` waits.
   - `BLOCKED` → relay to the PM: `ai-arena pm <slug> "Candidate <label> is BLOCKED,
     see worktree-tmp/<env_name>/arena-report.md"`. On `VERDICT: ANSWER` or
     `REDISPATCH`, `ai-arena resume <slug> <label> "<MESSAGE>"` (for `TO: all`, resume
     every non-finished candidate). On `ASK_USER`, ask the user, send the answer to
     the PM, resume with what it says.
   - `FAILED` → read `worktree-tmp/<env_name>/arena-run.log` and the report; if the
     cause is environmental (container, DB), fix through `spawn`/`resume`; if the
     candidate gave up, leave it and continue.
   - Still `running` long after its report says `STATUS: DONE`, or stuck on a dead
     provider → `ai-arena stop <slug> <label>` kills the harness and settles the state
     from the report; gate and judge it like any other finished candidate.
   - `PARTIAL` → treat like DONE for gating; the judge weighs it.
   Repeat until no candidate is `running`.
8. **Gate and collect.** `ai-arena gate <slug>` then `ai-arena collect <slug>`. Gates
   are mechanical (site bootstrap, config, PHPStan, PHPCS, PHPUnit on the changed custom
   modules, and `report`: the report's FILES and the changed files match both ways), inside
   each candidate's own project. A `report` failure usually means a stray file: read
   `candidates/<label>/gates/report.log` and resume the candidate. Report the gate table to
   the user before judging. If `collect` warns that the production code is identical, tell
   the user: the arena measured discipline, not design.
9. **Judge.** `ai-arena judge <slug>`, in the background. It first waits for the
   candidate reviews and puts them beside each diff (`review-self.md`, `review-x1.md`); it
   warns if a reviewer left files in a tree. Blind: the PM sees labels and collected copies
   only. It ranks, confirms or refutes each review finding, and writes
   `arena/<slug>/grafts.md`: what to port from the losers, cut ones included, and the
   confirmed findings on the winner to fix. On
   `VERDICT: BLOCKED` (no acceptable candidate), report why and ask the user whether to
   resume the best one with the PM's instructions or stop.
10. **Promote and graft.** `ai-arena promote <slug> <winner> --env` creates
   `feature/<slug>` and its environment under `worktree/`. It refuses files the report
   does not declare: remove them through a resume, or pass `--allow-undeclared` only when
   they belong. Then `ai-arena graft <slug>` in the background: the winner's harness ports
   the list into that environment, then it is gated. Pass the confirmed review
   findings on the winner with `ai-arena graft <slug> --message "..."` if the list did not
   cover them. Nothing there is committed: the user reviews and commits it.
11. **Final review (always).** `ai-arena review --arena <slug>`, in the background: inside
   the environment under `worktree/`, with its site, a fresh session of the harness that
   wrote the final code and the other candidates' harnesses review it in parallel against
   the brief, and a lead synthesises them with an agreement map. If that environment's AI
   containers are down it warns and reviews without the site: start it first. Send the
   Act-on items with `ai-arena graft <slug> --message "..."`, then run `review --arena`
   again: it checks those items and reviews what changed since, not the whole diff again.
   Stop when the verdict has no Act-on items; `ai-arena status <slug>` says whether the
   final code changed since its last review. Put Consider items that are product calls to
   the user.
12. **Reveal and compare.** `ai-arena reveal <slug>` shows which harness and model each
   label was and logs the win to `~/.ddev/ai-arena/wins.tsv`; `ai-arena compare <slug>`
   prints time, steps, tokens and cost per round plus tests and gates: use it for the
   comparison table you report, and say which candidates were cut.
13. **Clean.** `ai-arena clean <slug>` removes the candidates under `worktree-tmp/`
    and their `tmp/*` branches (the winner's too, once `feature/<slug>` contains it). Ask the user only if a
    candidate is still running or they asked to keep losers.

### Arenas planned by the PM

`init --plan-by pm` (or `AI_ARENA_PLAN_BY=pm`), and approaches mode by default, skip steps 4
and 5: after `init`, `ai-arena plan <slug>` in the background (the PM runs `code-review` in
PLAN mode over `main/<repo>` and writes the brief; read it as in step 5), then `spawn` and
`run`, which start every candidate fresh. Deadline and candidate reviews work the same. The judge
writes no `grafts.md`: review the winner with `ai-arena review --env worktree-tmp/<winner
env_name> --intent "<task>"`, resume it with the Act-on items, re-gate, then `promote`.

**Approaches mode** (the user wants to compare designs, not models: "misma tarea con dos
enfoques", "compare approach X vs Y"): same model for every label, usually `--candidates
opencode,opencode`, plus either `--approach "<text>"` once per label in order (the user
dictates them) or `--approaches` (the PM proposes one per label in `plan` and replies
`ASK_USER` with the list: put it to the user, send changes with `ai-arena pm <slug> "..."`,
spawn only once the user confirms). Approaches live in `arena/<slug>/approach-<label>.md`;
`status`, `reveal` and the judge show them. With one harness only the `self` review runs.

## Multi-model review (no arena)

`ai-arena review --arena <slug> | --branch <b> | --env <dir> | --patch <file> [--reviewers claude:opus,opencode] [--intent "..."]`
runs independent reviewers on different harnesses and models in the coordinator's
containers and a lead synthesis; it prints the verdict and leaves everything under
`arena/reviews/<id>/`. Use it when the user asks for a review, a second opinion, or
"tear this apart" on a branch or an environment's working tree. Report the Act-on list
first, then Consider, and name which reviews agreed.

## Ordinary environments (no arena)

- `worktree-add <branch>` creates `worktree/<base>-<branch>` from `main/` (existing,
  remote, or new branch), with the database and provisioning as above. Options:
  `--db snapshot|latest|file:<path>|export|none`, `--name`, `--base-ref`.
- `worktree-remove <branch|name|dir>` deletes containers, worktree, directory, and
  the branch (`--keep-branch` to keep it; `-y` when there is no terminal; `-f` with
  uncommitted changes, only after the user confirms). It refuses `main/` and anything
  outside `worktree/` and `worktree-tmp/`.
- `host-skills-sync` links the skills of `AI_ARENA_HOST_SKILL_REPOS` (extra, usually
  private, agent repositories) into the host harnesses; `--list` shows them.

## Reporting to the user

Answer first: winner, why (gates + rubric), what the losers had that was grafted or
worth grafting, which candidates were cut at the deadline, what the reviews and the
final review found and whether it is fixed, the `feature/<slug>` branch, and what the user does next (review the
diff, commit, open the PR: you never commit). Then the run facts: candidates, time,
anything skipped. Keep model names out of the judgment narrative until reveal.

## Guardrails

- One arena per task; `init --force` only when the user asks to restart. Several
  arenas can run at once; each has its own slug, sessions, and candidates.
- Never edit files inside `main/`, `worktree/`, or `worktree-tmp/`; talk to
  candidates through `resume`.
- Never run git write commands (commit, push, branch deletion) yourself; `promote`
  (which records the winner's working tree as one commit on its `tmp/` branch, since
  candidates never commit), `clean`, and `worktree-remove` are the only git operations.
  Tell the user the branch carries one work-in-progress commit to review and squash.
- If `wait` times out or this session is interrupted, `ai-arena status <slug>`
  reattaches: candidates ran detached and their state is on disk.
- Never kill candidate processes by hand inside a container: `ai-arena stop` is the
  only way, because the run wrapper that records the exit code must survive the kill.
- Questions to the user are the exception. Most BLOCKED questions are answered by
  the PM from the brief; escalate only `ASK_USER` verdicts, spawn failures you cannot
  fix, and the final decision when no candidate is acceptable.
