# Agent workflow (the "factory")

This document is the contract for autonomous Claude sessions working on OtterTwin.
The owner controls the work through GitHub only: issues, labels, PRs and the Roadmap issue (#40).
If this document and an issue disagree, the issue wins for that task. If anything is unclear
or risky, stop and ask (see "Escalation").

## 1. Environment facts

- Cloud agent sessions run on **Linux**. `xcodebuild`, `xcodegen`, the Swift toolchain and
  macOS frameworks are **not available**. Do not try to install them.
- The only source of truth for "it builds" and "tests pass" is the **macOS CI workflow** on
  GitHub Actions (introduced by #16). Read its results with the REST API:
  - `gh api repos/sibiryoff/ottertwin/commits/<sha>/check-runs`
  - `gh api repos/sibiryoff/ottertwin/actions/runs?branch=<branch>`
  - `gh api repos/sibiryoff/ottertwin/actions/jobs/<job_id>/logs` (failed job log)
  - GraphQL is unavailable from agent sessions; use REST only.
- Until #16 is merged, the only task an agent may work on is #16 itself.
- A CI round-trip takes several minutes. Batch your changes, then poll CI every 2–3 minutes
  (max ~45 minutes per run) instead of pushing many tiny commits.

## 2. Picking work

Every task issue ends with a factory block:

```
<!-- factory -->
Order: 12
Depends on: #6, #21
Autonomy: agent
```

Pick exactly **one** task per session:

1. If the Roadmap issue has the `factory-paused` label → do nothing, report "paused", stop.
2. Candidates = open issues labelled `agent-ready`, NOT labelled `story`, `gate`,
   `needs-human`, `blocked`, `in-progress` or `later`.
3. Drop candidates whose `Depends on:` lists any issue that is still open.
4. Issues labelled `bug` + `safety` go first. Otherwise take the lowest `Order`.
5. If an issue is labelled `in-progress` but has had no commits or comments for 24 hours,
   treat it as abandoned: take it over and say so in a comment.

Gate issues (`gate`) are for the owner. Agents never close them. A later milestone may start
while a gate is open; bugs reported from a gate become `bug` + `safety` issues and jump the queue.

## 3. Doing a task

1. Add the `in-progress` label and comment: what you are about to do (2–4 lines).
2. Branch: if the issue references an existing PR (e.g. #2, #7, #8), continue on **that PR's
   branch**, rebased onto current `main`. Otherwise create `agent/<issue>-<short-slug>` from `main`.
3. Implement the smallest change that meets every acceptance criterion.
4. Tests are mandatory:
   - every acceptance criterion maps to at least one automated test, or is explicitly listed in
     the PR under "Not covered by automation" with the reason;
   - file-operation code must be tested with the data-safety harness (#24 once merged):
     disposable fixture trees, independent comparison, fault injection;
   - never weaken, skip or delete an existing test to make CI green; never re-record snapshot
     baselines to hide a diff (re-record only when the UI change is intended, and say so in the PR).
5. New source files: the Xcode project is generated from `project.yml` in CI; do not hand-edit
   `project.pbxproj`.
6. Open a PR titled like the issue, body from the PR template, containing `Closes #<issue>`.
7. Wait for CI. On failure: read the log, fix, push. After 3 failed fix attempts on the same
   problem → escalate.

## 4. Review and merge rules

A PR may be merged by the agent (squash merge) only when **all** are true:

- the macOS CI check is green on the latest commit;
- an independent review was done: spawn a fresh-context reviewer subagent (it has not seen your
  reasoning) with the issue text and the diff; it must check correctness, data-safety, test
  coverage of each acceptance criterion. All its blocking findings are fixed;
- review comments from bots or humans on the PR are answered (fixed or explained);
- the issue is not labelled `needs-human`, and the PR does not change
  `.github/workflows/*`, entitlements, signing settings or `docs/agent-workflow.md`
  **unless the issue explicitly asks for it**;
- the PR description lists what was verified and what was not.

After merging: comment on the issue with a 3–6 line summary (what changed, tests added, anything
the owner should know), remove `in-progress`, and make sure the issue is closed. Then update the
Roadmap issue (section 6).

## 5. Data-safety rules (non-negotiable)

- Never delete or overwrite user data before the replacement is fully written, flushed and verified.
- A move deletes its source only after the destination copy is verified.
- Partial/temporary files are unique per operation and are always cleaned up on failure or cancel.
- Destructive UI actions require explicit confirmation; delete goes to Trash by default.
- Errors are never swallowed (`try?` on a data path is a bug unless commented why it is safe).
- No credentials, passwords or full SMB URLs with secrets in logs or reports.
- Tests use temporary directories only — never the real home folder, never `/Volumes/*` of the
  CI machine except disk images created by the test itself.

## 6. Reporting

- The Roadmap issue holds a status table. After each merged task, edit the table row
  (status + PR link) and the "Last factory run" line.
- When a milestone's last task is merged, comment on its gate issue: "Ready for your check",
  with the commit SHA and the exact steps from the gate checklist.

## 7. Escalation (stop and ask)

Label the issue `needs-human`, write one comment with: the question, the options you see,
your recommendation. Then stop working on that issue (you may pick another one). Escalate when:

- the issue is ambiguous in a way that changes behaviour visible to the owner;
- a change would weaken a data-safety rule above;
- CI is broken for reasons outside the task (runner image, GitHub outage) for more than one run;
- an action needs secrets, signing identities, or access to the owner's machine or NAS.
