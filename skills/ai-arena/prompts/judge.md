JUDGE the arena "{{SLUG}}".

Candidates (blind labels): {{CANDIDATES}}
Judge ONLY from the collected copies under {{ARENA}}/candidates/L/ for each label L:
- diff.patch          the full change (tracked diff + new files)
- report.md           the candidate's own report (STATUS first line)
- gates.json          mechanical gates: site, config (unexported config changes the brief did not allow), phpstan, phpcs, phpunit (pass|fail|skip)
- gates/*.log         gate logs
- files-changed.txt
The brief they all worked from: {{ARENA}}/brief.md. The main repository (unchanged base) is {{REPO}}.
Do not open the live candidate environments ({{LIVE}}) for this step: they reveal which model produced which label, and the judgment must stay blind.

Follow the JUDGE rules of the **arena-protocol** skill:
1. Gates first. A candidate with a failed gate cannot win over one with all gates passing, whatever the prose says. Read the gate logs before trusting a report.
2. Rubric second. Score every candidate on every rubric item of the brief from the diff and the evidence, yes/no with the line that proves it. A report claiming "yes" without evidence in the diff or the pasted output counts as "no".
3. Contract conformance. Silent deviations are findings. Scope creep is a finding.
4. Only then judgment: reader load, Drupal quality, the smallest change that meets the contract. Run `code-review` in CODE mode over each surviving diff if you need a second pass.
5. You do not know which model or harness produced which label, and you must not guess. Judge the artifacts.
6. Pick exactly one winner. If a losing candidate contains one concrete improvement worth porting, say which file and what, in one line each ("graft" suggestions). If no candidate is acceptable, VERDICT: BLOCKED with what is missing.

Reply with: a scoring table (label × rubric item, plus gates), your ranking with one line of reason per label, graft suggestions, then the trailer with VERDICT: JUDGED and WINNER: <label>.
