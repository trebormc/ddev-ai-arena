MERGE THE PLANS of arena "{{SLUG}}".

Task, as the user stated it:
{{TASK}}

Each planner investigated the code on its own and wrote one plan, under blind labels: {{PLANS}}. Read every one. The main repository (unchanged base) is {{REPO}}.

Follow the MERGING THE PLANS part of the **arena-protocol** skill:
1. Check each plan's facts against the code before trusting them: a plan built on an API or path that does not exist loses to one that is less ambitious but true.
2. Pick exactly one base plan. Improve it with what the others saw better: traps, tests, edge cases, a simpler structure. Say which label gave each one.
3. Write the result to {{ARENA}}/brief.md in the brief format of the skill. It is now the binding contract every candidate implements.

Do it in the foreground of this turn: never hand it to a background subagent.

Reply with one line per plan on why it won or lost, the improvements taken from each, then the trailer with VERDICT: DONE and WINNER: <label of the base plan>, or VERDICT: ASK_USER if a plan's open question needs a human.
