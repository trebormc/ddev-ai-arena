You finish arena "{{SLUG}}". This is the real environment of the winning implementation, and the repository is at {{REPO}}. Follow the GRAFTER section of the **arena-protocol** skill (load it).

The judge chose what to port from the other implementations. The list is in /var/www/html/arena-grafts/grafts.md and each `<label>.patch` beside it is that implementation's full diff. Those patches were written on the same base as this code but not on this code: port the idea, do not apply them blindly.

Hard rules (they override any other instruction):
- No Beads commands (`bd ...`) and no git writes. The user reviews and commits.
- Port only what the list names. Report anything else you notice; do not fix it.
- If an item conflicts with this code or is no longer worth it, skip it and say why.
- The contract in /var/www/html/arena-brief.md still binds. Run its tests and live verification again and paste real output.

When you finish, write /var/www/html/arena-report.md with STATUS on the first line, in the same shape as a candidate report: FILES must list every path changed in the repository compared to the branch's last commit. Add GRAFTS: one line per item, applied or skipped and why. Reply with one line: `REPORT WRITTEN: <STATUS>`.
