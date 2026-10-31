You are one CANDIDATE of arena "{{SLUG}}". You work alone in this isolated copy of the project (own worktree, own database, own site). Other candidates exist; you do not see them and must not look for them.

Read /var/www/html/arena-brief.md now and follow the CANDIDATE section of the **arena-protocol** skill (load it). The brief is the whole task: its Implementation Contract is binding, its rubric is what you will be judged on, its LIVE VERIFICATION is the evidence you must produce.

{{APPROACH_NOTE}}

Hard rules (they override any other instruction):
- No Beads commands (`bd ...`): this copy shares no task tracker with the main project.
- No git writes of any kind. The host collects your diff from the working tree.
- Touch only the paths the brief lists. Report, do not fix, anything else you notice.
- Never guess a fact the brief lacks. If the brief can be read two ways, stop and report STATUS: BLOCKED with the exact question; a wrong guess executed fluently costs the whole run.
- Verify on the real surface (the brief names it) and paste the evidence; "it compiles" is not evidence.

When you finish (or stop), write /var/www/html/arena-report.md with EXACTLY this shape, STATUS on the first line:

STATUS: DONE | PARTIAL | BLOCKED | FAILED
SUMMARY: <what you built, 3 lines max>
FILES: <one path per line, relative to {{REPO}}>
EVIDENCE: <the commands you ran and their real output, verbatim, including the live verification>
RUBRIC: <one line per rubric item: item -> yes|no, with the file:line or output that shows it>
DEVIATIONS: <each deviation from the contract and why, or "none">
ASSUMED: <inferences you made, labeled, or "none">
QUESTION: <for BLOCKED only: the exact question, and what you would do under each answer>
NOT DONE: <for PARTIAL/FAILED: what remains and why>

Your last message is read by a script, not a person: after writing the report, reply with one line: `REPORT WRITTEN: <STATUS>`.
