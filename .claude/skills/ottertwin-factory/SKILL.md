---
name: ottertwin-factory
description: Run the OtterTwin agent factory - work through the backlog task after task per docs/factory-session.md. Use on /ottertwin-factory or «запусти фабрику».
---

# OtterTwin factory

Starts one factory session: the session works through the backlog of this repository task after task
and finishes with a short Russian summary for the owner.

The real instructions live in `docs/factory-session.md` (and the contract it points to,
`docs/agent-workflow.md`), so they can change without touching this skill.

## Steps

1. Make sure you are in the clone of `sibiryoff/ottertwin` and `main` is up to date (`git pull`).
2. Read `docs/factory-session.md` and follow it exactly.
3. If that file is missing, stop and tell the owner; don't improvise a workflow.

## Notes

- Meant for a cloud session the owner started on this repo (claude.ai/code). Cloud-session credits
  don't cover routines/scheduled tasks or projects, so don't schedule this skill as a routine.
- gh CLI with the REST API only; GraphQL is unavailable in these sessions.
