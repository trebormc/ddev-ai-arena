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
  - user: "lanza una arena para añadir la tasa de gestión al total, tres candidatos" -> up, init, plan, spawn, run, wait loop, judge, promote, reveal, clean
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

The scripts live next to this file in `scripts/` (`ai-arena`, `worktree-add`,
`worktree-remove`); `ai-arena` is also on the PATH after `install.sh`. The user talks
only to you; layers 2 and 3 never talk to the user.

Everything mechanical is a verb of `ai-arena`; everything that needs Drupal judgment
happens inside AI containers through `plan`, `pm`, and `judge`. You decide which verb
comes next and read JSON. `ai-arena status <slug> --json` is the source of truth.

## The run

1. **Bring up layer 2.** `ai-arena doctor`, then `ai-arena up` if the coordinator's
   containers are not running. Fix or report what doctor flags.
2. **Init.** `ai-arena init "<task in the user's words>" [--candidates claude:opus,claude:sonnet,opencode] [--description "..."]`.
   Prints the slug. Default panel and cap (max 3) come from `ai-arena.env`. Different
   harnesses and models per label are the point: keep the panel diverse unless the
   user names one.
3. **Plan.** `ai-arena plan <slug>`. The PM session (coordinator container) runs
   `code-review` in PLAN mode over `main/<repo>` and writes `arena/<slug>/brief.md`.
   Read the brief. On `VERDICT: ASK_USER`, put the question to the user, then
   `ai-arena pm <slug> "<answer>"` and ask it to write the brief. Do not spawn without
   a brief.
4. **Bring up layer 3.** `ai-arena spawn <slug>`. For each candidate, `worktree-add
   --tmp` copies the main environment, creates the worktree on `tmp/<slug>-<label>`,
   starts its DDEV project `<base>-tmp-<slug>-<label>`, provisions the database
   (baseline snapshot, newest `backups/` dump, or an export of main) and runs composer
   and drush. Minutes per candidate; run it in the background and keep the user
   informed. A failed spawn for one label is not fatal: report it, continue.
5. **Run.** `ai-arena run <slug>`. Detached; candidates keep working even if this
   session ends.
6. **Wait loop.** `ai-arena wait <slug>` blocks until any candidate changes state
   (`--all` for all). Run it in the background with a long timeout and react:
   - `DONE` → keep waiting for the rest.
   - `BLOCKED` → relay to the PM: `ai-arena pm <slug> "Candidate <label> is BLOCKED,
     see worktree-tmp/<env_name>/arena-report.md"`. On `VERDICT: ANSWER` or
     `REDISPATCH`, `ai-arena resume <slug> <label> "<MESSAGE>"` (for `TO: all`, resume
     every non-finished candidate). On `ASK_USER`, ask the user, send the answer to
     the PM, resume with what it says.
   - `FAILED` → read `worktree-tmp/<env_name>/arena-run.log` and the report; if the
     cause is environmental (container, DB), fix through `spawn`/`resume`; if the
     candidate gave up, leave it and continue.
   - `PARTIAL` → treat like DONE for gating; the judge weighs it.
   Repeat until no candidate is `running`.
7. **Gate and collect.** `ai-arena gate <slug>` then `ai-arena collect <slug>`. Gates
   are mechanical (site bootstrap, PHPStan, PHPCS, PHPUnit on the changed custom
   modules, inside each candidate's own project). Report the gate table to the user
   before judging.
8. **Judge.** `ai-arena judge <slug>`. Blind: the PM sees labels and collected copies
   only. Read the ranking and graft suggestions. On `VERDICT: BLOCKED` (no acceptable
   candidate), report why and ask the user whether to resume the best one with the
   PM's instructions or stop.
9. **Promote and reveal.** `ai-arena promote <slug> <winner> [--env]` creates
   `feature/<slug>` in the main repository (with `--env`, also its environment under
   `worktree/`). Then `ai-arena reveal <slug>` shows which harness and model each
   label was and logs the win to `~/.ddev/ai-arena/wins.tsv`.
10. **Clean.** `ai-arena clean <slug>` removes the candidates under `worktree-tmp/`
    and their `tmp/*` branches (the winner's branch is kept). Ask the user only if a
    candidate is still running or they asked to keep losers.

## Multi-model review (no arena)

`ai-arena review --branch <b> | --env <dir> | --patch <file> [--reviewers claude:opus,opencode] [--intent "..."]`
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
  the branch (`--keep-branch` to keep it; `-f` with uncommitted changes, only after
  the user confirms). It refuses `main/` and anything outside `worktree/` and
  `worktree-tmp/`.

## Reporting to the user

Answer first: winner, why (gates + rubric), what the losers had that was grafted or
worth grafting, the `feature/<slug>` branch, and what the user does next (review the
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
- Questions to the user are the exception. Most BLOCKED questions are answered by
  the PM from the brief; escalate only `ASK_USER` verdicts, spawn failures you cannot
  fix, and the final decision when no candidate is acceptable.
