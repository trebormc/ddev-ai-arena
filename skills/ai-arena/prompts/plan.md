PLAN the arena "{{SLUG}}".

Task, as the user stated it:
{{TASK}}

Candidate labels that will work on it in parallel, each in its own isolated copy of this project: {{CANDIDATES}}

{{APPROACHES}}

Do this now:
1. Run the Plan step exactly as CLAUDE.md prescribes: invoke `code-review` in PLAN mode with the task as an OUTCOME, the relevant paths (use `code-explorer` to locate them), and any constraints. Resolve every Open Question yourself from the codebase; if one truly needs the user, do not write the brief: reply with VERDICT: ASK_USER and the question.
2. Write the brief to {{ARENA}}/brief.md following the BRIEF FORMAT of the **arena-protocol** skill: the Implementation Contract verbatim, a MECHANICAL RUBRIC of 3-6 yes/no checks a reviewer can verify from a diff and gate logs, the LIVE VERIFICATION the candidate must run and paste as evidence, the constraints (no Beads commands, no git commits, touch only the listed paths, and one explicit line `Config changes: allowed` or `Config changes: not allowed`, which the config gate reads), and the REPORT FORMAT the candidate must write to /var/www/html/arena-report.md.
3. Reply with a two-line summary of the chosen approach and the trailer with VERDICT: DONE (or ASK_USER).
