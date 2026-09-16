JUDGE the arena "{{SLUG}}".

Candidates (blind labels): {{CANDIDATES}}
For each label L the host collected, in this project's mount:
- {{ARENA}}/candidates/L/diff.patch      the full change (tracked diff + new files)
- {{ARENA}}/candidates/L/report.md       the candidate's own report (STATUS first line)
- {{ARENA}}/candidates/L/gates.json      mechanical gates: site, phpstan, phpcs, phpunit (pass|fail|skip)
- {{ARENA}}/candidates/L/gates/*.log     gate logs
- {{ARENA}}/candidates/L/files-changed.txt
The brief they all worked from: {{ARENA}}/brief.md. The repository root is {{REPO}}.

Follow the JUDGE rules of the **arena-protocol** skill:
1. Gates first. A candidate with a failed gate cannot win over one with all gates passing, whatever the prose says. Read the gate logs before trusting a report.
2. Rubric second. Score every candidate on every rubric item of the brief from the diff and the evidence, yes/no with the line that proves it. A report claiming "yes" without evidence in the diff or the pasted output counts as "no".
3. Contract conformance. Silent deviations are findings. Scope creep is a finding.
4. Only then judgment: reader load, Drupal quality, the smallest change that meets the contract. Run `code-review` in CODE mode over each surviving diff if you need a second pass.
5. You do not know which model or harness produced which label, and you must not guess. Judge the artifacts.
6. Pick exactly one winner. If a losing candidate contains one concrete improvement worth porting, say which file and what, in one line each ("graft" suggestions). If no candidate is acceptable, VERDICT: BLOCKED with what is missing.

Reply with: a scoring table (label × rubric item, plus gates), your ranking with one line of reason per label, graft suggestions, then the trailer with VERDICT: JUDGED and WINNER: <label>.
