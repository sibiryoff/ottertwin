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

- Find `.xcodeproj` or `.xcworkspace` in the project root
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
  - **Snapshot mismatch** → if the UI change was intentional, update the reference snapshot (re-run the test with `record: .all`); if not — this is a regression, fix the UI code
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
