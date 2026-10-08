---
name: run-ui-tests
description: >
  Runs XCUITest UI tests and swift-snapshot-testing snapshot tests for a macOS SwiftUI app.
  Use this skill whenever the user asks to run tests, check if tests pass, verify UI after
  changes, fix failing tests, or says something like "run the tests", "are tests green",
  "check UI tests", or "test the app". Also triggers on phrases like "something broke",
  "did I break anything", or "validate my changes" in a macOS/SwiftUI project context.
---

# Run UI & Snapshot Tests

Run all UI tests and snapshot tests for the project, analyze results, and fix any failures.

## Steps

### 1. Identify project parameters

- If the project has a `project.yml` (XcodeGen), the `.xcodeproj` is generated and not tracked in git: run `xcodegen generate` first (OtterTwin: XcodeGen 2.42.0, Xcode 16.4, schemes `OtterTwinTests` and `OtterTwinUITests`)
- Find `.xcodeproj` or `.xcworkspace` in the project root
- On a Linux agent session you cannot run these commands; read the macOS CI results (`.github/workflows/macos-ci.yml`) instead
- Identify the scheme that contains the UI Test target (usually `<AppName>UITests`)
- If the scheme is unknown, run: `xcodebuild -list`

### 2. Run the tests

```bash
xcodebuild test \
  -scheme <SCHEME_NAME> \
  -destination 'platform=macOS' \
  -only-testing:<UI_TEST_TARGET> \
  -resultBundlePath /tmp/TestResults.xcresult \
  2>&1 | tee /tmp/test-output.log
```

If the project also has ViewModel unit tests, run those too:
```bash
xcodebuild test \
  -scheme <SCHEME_NAME> \
  -destination 'platform=macOS' \
  -only-testing:<UNIT_TEST_TARGET> \
  2>&1 | tee -a /tmp/test-output.log
```

### 3. Analyze results

- Parse xcodebuild output: find lines matching `Test Case ... passed` and `Test Case ... failed`
- For each failing test, determine the root cause:
  - **Element not found** → check accessibility identifier in the app source
  - **Timeout** → increase timeout in `waitForExistence` or verify the UI element actually appears
  - **Snapshot mismatch** → if not intentional, it is a regression: fix the UI code. If the UI change was intentional, never re-record silently: in OtterTwin, baselines are recorded on CI (push a `ci/record-snapshots/<name>` branch, see README → Continuous integration) and land in a dedicated PR with before/after images (`docs/agent-workflow.md` §3.4). OtterTwin baselines are @1x from CI, so snapshot tests always fail on a local Retina Mac — that is expected, not a reason to re-record
  - **Crash** → inspect the crash log, fix the bug in the app
  - **Assertion failure** → review the test logic and app behavior

### 4. Fix failures

- For each failing test: fix either the app code or the test itself depending on the root cause
- Re-run only the failing tests to verify the fix:
  ```bash
  xcodebuild test \
    -scheme <SCHEME_NAME> \
    -destination 'platform=macOS' \
    -only-testing:<TARGET>/<TestClass>/<testMethod> \
    2>&1
  ```

### 5. Iterate until green

- If tests are still failing, return to step 3
- Maximum 3 iterations; if a test remains unstable after 3 attempts, mark it as flaky and report it

### 6. Report

Output a summary table:

```
✅ Passed: XX
❌ Failed: XX (after fixes: XX)
⚠️  Flaky:  XX
⏱  Time:   XX sec

Breakdown by category:
- Navigation:     X/X ✅
- File Table:     X/X ✅
- Sorting:        X/X ✅
- Keyboard:       X/X ✅
- Toolbar:        X/X ✅
- Dialogs:        X/X ✅
- Snapshots:      X/X ✅
- ViewModel:      X/X ✅
```

## Rules

- Do not modify tests just to make them pass — if a test found a bug, fix the bug
- If a snapshot test failed due to an intentional UI change, ask for confirmation before updating the reference snapshot
- Do not add `sleep()` to fix flaky tests — use proper waits (`waitForExistence`, `XCTNSPredicateExpectation`)
- If a test fails because an accessibility identifier is missing, add it to the app source code
