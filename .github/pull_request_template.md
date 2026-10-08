Closes #

## What changed
<!-- 2–5 bullets -->

## Acceptance criteria → evidence
<!-- one line per criterion from the issue: test name, CI job, or "manual: <steps>" -->
- [ ] 

## Data-safety checklist
- [ ] No user data is deleted/overwritten before the replacement is written, flushed and verified
- [ ] Failure and cancellation paths clean up temporary files and leave the source intact
- [ ] No errors swallowed on data paths (`try?` justified in a comment where used)
- [ ] Tests use temporary directories / disk images only

## Not covered by automation
<!-- what was NOT verified and why (e.g. real NAS, XCUITest) -->

## Review
- [ ] Independent reviewer subagent run; blocking findings fixed
- [ ] macOS CI green on the latest commit
