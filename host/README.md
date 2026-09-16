# Host setup for ai-arena

The `ddev ai-arena` command runs on the host. The AI harness you talk to on the host
(Claude Code or OpenCode, outside any container) is the "layer 1" that drives it. It
needs one skill so it knows the verbs and the loop. Nothing else is installed on the
host.

## 1. Install the skill in your host harness

Claude Code (user level, all projects):

```bash
mkdir -p ~/.claude/skills/ai-arena
cp host/skills/ai-arena/SKILL.md ~/.claude/skills/ai-arena/SKILL.md
```

OpenCode (global config directory):

```bash
mkdir -p ~/.config/opencode/skills/ai-arena
cp host/skills/ai-arena/SKILL.md ~/.config/opencode/skills/ai-arena/SKILL.md
```

Both tools discover skills from those directories on the next session. The same file
works in both.

## 2. Host requirements

- `ddev` (1.24.10+), `docker`, `git`, `jq` on the PATH.
- The main project has the AI workspace add-ons installed and running
  (`ddev-claude-code` and/or `ddev-opencode`, plus their dependencies), because the
  project-manager session and every candidate run inside those containers.
- Enough disk and memory for N extra DDEV projects (each candidate is a full project:
  web, db, and the AI containers). The default cap is 3.
- Optional: the `ai-notify-bridge` on port 5454 for desktop notifications when a
  session finishes or needs you.

## 3. Where to run it

From the MAIN project directory (the one with `.ddev/` that your host harness opens):

```bash
cd projects/<project>/worktree/<base>   # or the repo root in a standard layout
ddev ai-arena doctor
```

Candidate environments are created as sibling directories:
`../<site>-tmp-<slug>-<label>` on branches `tmp/<slug>-<label>`. The winner is
promoted to `feature/<slug>`.

## 4. Drive it from the host harness

Open your host harness in that directory and ask for an arena in plain words. The
skill maps the request to the verbs: `init`, `plan`, `spawn`, `run`, the `wait` loop
(with `pm` and `resume` for questions), `gate`, `collect`, `judge`, `promote`,
`reveal`, `clean`. You can also run any verb yourself; `ddev ai-arena --help` lists
them.

## 5. Configuration

`.ddev/.env.ai-arena` in the main project (created on install): default candidate
panel, PM harness and model, cap, timeout, database source (snapshot name, file, or
export), extra local files to copy, provisioning steps, and optional spawn/remove
hooks that replace the built-in environment creation with your own script.

Candidate models are applied through the per-project `.ddev/.env.agents` cascade that
`ddev-agents-sync` already honours (`CC_MODEL_*` / `OC_MODEL_*`), plus the harness's
`--model` flag for the top-level session, so nothing in the agents repos changes per
candidate.
