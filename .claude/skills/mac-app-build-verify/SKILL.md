---
name: mac-app-build-verify
description: Use after any code change to the Smart OS File Store macOS app (Swift, SwiftUI, XcodeGen) to regenerate the project, build, run tests and launch the app before reporting work as done.
---

# Build, test and verify the Mac app

This app is a production macOS app built with Swift, SwiftUI and XcodeGen. The owner edits in VS Code and does not use the Xcode editor. Never report a change as done until every step below has passed. If a step fails, fix the cause and start again from step 1.

## Steps

1. **Regenerate the project** whenever `project.yml` changed or files were added, moved or removed:
   ```bash
   xcodegen generate
   ```
   The `.xcodeproj` is generated output. Never edit it by hand; change `project.yml` instead.

2. **Find the scheme name** from `project.yml` (the app target's name), or with `xcodebuild -list`. Use it as `<Scheme>` below.

3. **Build** into a local folder so results are easy to find:
   ```bash
   xcodebuild -scheme <Scheme> -destination 'platform=macOS' -derivedDataPath build build 2>&1 | tail -40
   ```
   The bar is zero errors and zero warnings. Treat a new warning as a failure and fix it, including Swift 6 strict concurrency warnings. Do not silence warnings with flags or annotations unless the reason is written in a comment.

4. **Run the tests:**
   ```bash
   xcodebuild -scheme <Scheme> -destination 'platform=macOS' -derivedDataPath build test 2>&1 | tail -60
   ```
   Every test must pass. Never delete, skip or weaken a test to get a pass. Tests must only touch temporary folders they create themselves, never the real Downloads folder or any other real user folder.

5. **Launch the app** and check the change in the running app, not only in tests:
   ```bash
   open build/Build/Products/Debug/<AppName>.app
   ```
   Confirm it opens without crashing. For anything visual, say exactly what the owner should see and click to check it, because they test by hand.

6. **Keep the build folder out of git.** Make sure `build/` is in `.gitignore`.

## Reporting

End with a short report: what changed, the build result, the test count and result, and what was checked in the running app. If any step was skipped or could not be run, say so plainly and say why. Do not describe work as verified when it was not.

## When something fails

- **`xcodegen: command not found`:** it is installed with Homebrew; check `brew list xcodegen` and the PATH before reinstalling anything.
- **`xcodebuild` complains about the license or a missing developer directory:** stop and tell the owner, since fixing it needs their password.
- **Signing errors in a debug build:** use automatic signing with "Sign to Run Locally" in `project.yml`. Do not add a paid team id unless the owner supplies one.
