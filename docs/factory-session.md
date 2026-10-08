# Factory session (manual cloud session)

The owner starts a Claude Code cloud session on this repository (claude.ai/code → new cloud session →
repo `sibiryoff/ottertwin`) and pastes one line:

> Read docs/factory-session.md and follow it.

The session then works through the backlog on its own, task after task, until it runs out of work it
can do. Cloud sessions (unlike routines/scheduled tasks) are covered by the cloud-session credit, which
is why the factory runs this way.

## Instructions for the session

1. Read `docs/agent-workflow.md` in full and `CLAUDE.md`. They are the contract. Roadmap and status: issue #40.
   You are on Linux: no `xcodebuild`/`xcodegen`; the macOS GitHub Actions workflow is the only build/test
   signal. Use the gh CLI with the REST API only (GraphQL is unavailable). Until #16 is merged, #16 is the
   only task you may work on.
2. If issue #40 has the label `factory-paused`, stop and say so.
3. Housekeeping (once at the start, and again after each task):
   - Gate issues (label `gate`): for each problem the owner reported in a comment since the last factory
     comment, create a `bug` + `safety` + `agent-ready` issue with the standard factory block
     (Story = the gate's story, Order: 0, Depends on: none, Autonomy: agent), add it as a sub-issue of that
     story (`POST /repos/sibiryoff/ottertwin/issues/{story}/sub_issues` with the new issue's `id`), add a row
     to the #40 table and reply on the gate with links. Never close gate issues.
   - An open issue labelled `in-progress` is unfinished work from an earlier session: resume it first.
4. **Loop:** pick the next task per section 2 of `docs/agent-workflow.md`, and do it per sections 3–5.
   To keep this session's context small, delegate each task to a fresh subagent: give it the issue number,
   tell it to read `docs/agent-workflow.md` and the issue, implement, push, open/update the PR and poll CI
   until green. Then you (the orchestrator) run a *separate* fresh-context reviewer subagent on the diff,
   send blocking findings back for fixing, check the merge rules yourself, merge, and do the reporting from
   section 6 (update #40, comment on the issue, comment "Ready for your check" on the gate when a milestone's
   last task is merged).
5. Stop the loop when any of these is true, and finish with a short Russian summary for the owner
   (date; tasks merged this session with numbers; what is next; what is needed from the owner, if anything):
   - no task is pickable (everything left is blocked, `needs-human`, or a gate waiting for the owner);
   - the same task failed CI 3 times after fixes (escalate it per section 7, then continue with another task
     if one is pickable);
   - you have merged 6 tasks in this session (the owner starts a fresh session to continue; long sessions
     get slow and expensive).
6. Never: force-push or rewrite `main`; push to `main` except via merged PRs; delete branches other than
   your own merged PR branches; close gate issues; change `.github/workflows/*`, entitlements, signing
   settings or `docs/agent-workflow.md` unless the task explicitly asks; print or store secrets.
