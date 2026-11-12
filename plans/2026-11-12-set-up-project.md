# Plan: Set up the Smart OS File Store project

## Context

The folder `/Users/cadensun/Developer/smart-os-file-store` holds only `CLAUDE.md` (the source of truth) and an empty `plans/` folder. This segment bootstraps the whole project: project skills, git, the XcodeGen spec, a placeholder app, the `FileStoreCore` engine framework with its first type (`ScanLocation`), unit tests, VS Code indexing, README, CI, verification, and one commit. No cleanup features yet. The outcome is a warning-free, tested, launchable skeleton that every later segment builds on.

The owner asked for the plan to live in `plans/`. Plan mode only allows writing this file, so step 0 below copies it into the project.

### Facts gathered (verified on this machine and on GitHub, 2026-11-12)

| Item | Value |
|---|---|
| Local Xcode | 27.2 (27B52) at `/Applications/Xcode.app`, Swift 6.4.2, macOS 27.2.1 |
| Tools present | xcodegen 2.46.0, xcode-build-server, gh 2.103.3, brew, git 2.54 |
| gh auth | Signed in as `Quaden2307`, scopes `repo`, `workflow`, `read:org`, `gist` |
| GitHub repo | `Quaden2307/smart-os-file-store` does not exist yet |
| VS Code | 1.146.0 with Swift extension 2.18.0 |
| CI image | `xcode-27` (arm64, status **Preview** in the runner-images README, image 20261104.0337.1, macOS 27.0.1) ships Xcode 27.0, 27.1 (default) and **27.2 (27B52)**. `macos-26` / `macos-latest` only go up to Xcode 26.6. Neither image preinstalls xcodegen. |
| actions/checkout | latest release v7.0.1 |

### Decisions

- **Bundle id:** `com.quaden2307.SmartOSFileStore` (owner's choice). Framework `com.quaden2307.FileStoreCore`, tests `com.quaden2307.FileStoreCoreTests`. `bundleIdPrefix: com.quaden2307` in project.yml.
- **CI runner:** `runs-on: xcode-27`, then `sudo xcode-select -s /Applications/Xcode_27.2.app` so CI uses the exact same Xcode build as the owner's machine. Tell the owner it is a preview-status image. Deployment target stays 26.0.
- **Generated `Info.plist`:** XcodeGen writes it to `SmartOSFileStore/Info.plist` on every `xcodegen generate`. It is committed (deterministic output, and the `.gitignore` list in CLAUDE.md is kept exactly as written plus `buildServer.json`).
- **Debug-only override:** implemented with `#if DEBUG` inside `FileStoreCore`, so release builds compile the override parsing out entirely. XcodeGen's default Debug config defines `DEBUG`.
- **Hardened Runtime** is set on the app target only (it is a process-level setting; putting it on the test bundle buys nothing).
- No asset catalog / app icon in this segment (not requested). If Xcode 27 warns about a missing icon, fix the cause (add an empty catalog) rather than silencing.

---

## Steps (in order)

### 0. Copy this plan into the project
Write this file to `plans/2026-11-12-set-up-project.md` so it is committed with the project.

### 1. Project skills
Create, byte-for-byte from the prompt (frontmatter included):
- `.claude/skills/mac-app-build-verify/SKILL.md`
- `.claude/skills/cleanup-test-fixtures/SKILL.md`
- `.claude/skills/add-cleanup-action/SKILL.md`

### 2. Git
```bash
git init -b main
```
`.gitignore` (CLAUDE.md list + buildServer.json):
```
build/
*.xcodeproj
DerivedData/
.DS_Store
xcuserdata/
.swiftpm/
buildServer.json
```
A stray `.DS_Store` already sits in the folder; the ignore covers it.

### 3. `project.yml`
```yaml
name: SmartOSFileStore
options:
  bundleIdPrefix: com.quaden2307
  deploymentTarget: { macOS: "26.0" }
  developmentLanguage: en
  xcodeVersion: "27.2"
  createIntermediateGroups: true
settings:                       # applies to every target and configuration
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    SWIFT_TREAT_WARNINGS_AS_ERRORS: YES
    GCC_TREAT_WARNINGS_AS_ERRORS: YES
    ARCHS: arm64
    MACOSX_DEPLOYMENT_TARGET: "26.0"
    ENABLE_APP_SANDBOX: NO
    CODE_SIGN_STYLE: Automatic
    CODE_SIGN_IDENTITY: "-"       # Sign to Run Locally
    DEVELOPMENT_TEAM: ""
    LOCALIZATION_PREFERS_STRING_CATALOGS: YES
    SWIFT_EMIT_LOC_STRINGS: YES
targets:
  SmartOSFileStore:
    type: application
    platform: macOS
    sources: [SmartOSFileStore]          # includes Localizable.xcstrings
    dependencies:
      - target: FileStoreCore            # embed + link (XcodeGen default for frameworks in an app)
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.quaden2307.SmartOSFileStore
        ENABLE_HARDENED_RUNTIME: YES
    info:
      path: SmartOSFileStore/Info.plist
      properties:
        CFBundleDisplayName: Smart OS File Store
        CFBundleShortVersionString: "0.1.0"
        CFBundleVersion: "1"
        LSApplicationCategoryType: public.app-category.productivity
        LSMinimumSystemVersion: $(MACOSX_DEPLOYMENT_TARGET)
        NSPrincipalClass: NSApplication
        NSDownloadsFolderUsageDescription: >-
          Smart OS File Store lists and cleans up files in your Downloads folder
          only when you ask it to.
  FileStoreCore:
    type: framework
    platform: macOS
    sources: [FileStoreCore]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.quaden2307.FileStoreCore
        SKIP_INSTALL: YES
  FileStoreCoreTests:
    type: bundle.unit-test
    platform: macOS
    sources: [FileStoreCoreTests]
    dependencies:
      - target: FileStoreCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.quaden2307.FileStoreCoreTests
schemes:
  SmartOSFileStore:               # shared scheme
    build:
      targets:
        SmartOSFileStore: all
        FileStoreCore: all
        FileStoreCoreTests: [test]
    run:  { config: Debug }
    test: { config: Debug, targets: [FileStoreCoreTests] }
    archive: { config: Release }
```
Exact keys may be adjusted if `xcodegen generate` rejects one; the settings above are the contract.

### 4. Minimal code

**App** (`SmartOSFileStore/`):
- `SmartOSFileStoreApp.swift`: `@main struct SmartOSFileStoreApp: App` with a single `Window("Smart OS File Store", id: "main") { ContentView() }.defaultSize(width: 720, height: 480)`. `Window` gives exactly one main window.
- `ContentView.swift`: `ContentUnavailableView("No Files Yet", systemImage: "folder", description: Text("Files in your Downloads folder will appear here."))`. System control, system colours, keyboard-neutral, built-in accessibility. Reads no files; does not import `FileStoreCore` yet (nothing to call).
- `Localizable.xcstrings`: start as `{"sourceLanguage":"en","strings":{},"version":"1.0"}`; the first build's string extraction fills it, and the filled file is what gets committed.
- `Info.plist`: generated by XcodeGen from the spec above.

**Engine** (`FileStoreCore/ScanLocation.swift`, Foundation only, no SwiftUI/AppKit):
```swift
public struct ScanLocation: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case downloadsFolder, launchArgument, environmentVariable }
    public let folderURL: URL
    public let source: Source
    public static let launchArgumentName = "-ScanFolder"
    public static let environmentVariableName = "SMARTOS_SCAN_FOLDER"

    public static func resolve(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(ScanLocationError) -> ScanLocation
}

public enum ScanLocationError: Error, Sendable, Equatable {
    case downloadsFolderUnavailable
    case overrideValueMissing(source: ScanLocation.Source)        // "-ScanFolder" given with no path
    case overrideDoesNotExist(path: String, source: ScanLocation.Source)
    case overrideIsNotAFolder(path: String, source: ScanLocation.Source)
}
```
Behaviour:
- Default: `FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first`, else `.downloadsFolderUnavailable`. Computing the URL does not read the folder.
- `#if DEBUG` only: look for `-ScanFolder <path>` in `arguments` (first occurrence; value is the next element); if absent, use a non-empty `SMARTOS_SCAN_FOLDER`. Launch argument wins when both are set, and the environment value is then not even validated. Release builds skip this block entirely.
- Override path: tilde-expanded, `URL(fileURLWithPath:).standardizedFileURL`; checked with `fileExists(atPath:isDirectory:)`. Missing → `overrideDoesNotExist`; a file → `overrideIsNotAFolder`. No `try!`, no force unwraps, no `fatalError`.
- Edge decisions made here (small, documented in doc comments): empty env var counts as unset; `-ScanFolder` as the last argument is `overrideValueMissing`.

**Tests** (`FileStoreCoreTests/ScanLocationTests.swift`, Swift Testing, `import Testing`, `import FileStoreCore`):
- Helper `withTemporaryFolder` creates `FileManager.default.temporaryDirectory/<UUID>` and removes it in `defer`. Nothing touches real user folders.
- `defaultIsDownloadsFolder`: no args/env → `source == .downloadsFolder`, URL equals FileManager's downloads URL.
- `launchArgumentOverridesDownloads`
- `environmentVariableOverridesDownloads`
- `launchArgumentWinsOverEnvironmentVariable` (two different temp folders)
- `missingOverridePathIsTypedError` → `#expect(throws: ScanLocationError.overrideDoesNotExist(...))`
- `fileOverridePathIsTypedError` (temp file, not folder) → `.overrideIsNotAFolder`
- `launchArgumentWithoutValueIsTypedError` → `.overrideValueMissing`
Expected count: 7 tests.

### 5. VS Code support
```bash
xcodegen generate
xcode-build-server config -scheme SmartOSFileStore -project SmartOSFileStore.xcodeproj
```
`buildServer.json` is git-ignored (local paths).

### 6. `README.md`
One paragraph (what the app is, from CLAUDE.md), then commands:
```bash
xcodegen generate
xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' -derivedDataPath build build
xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' -derivedDataPath build test
open build/Build/Products/Debug/SmartOSFileStore.app
# hand testing against a fake folder (debug builds only):
open build/Build/Products/Debug/SmartOSFileStore.app --args -ScanFolder /path/to/FakeDownloads
# or: SMARTOS_SCAN_FOLDER=/path/to/FakeDownloads open build/Build/Products/Debug/SmartOSFileStore.app
```
Plus the `xcode-build-server config` line for VS Code, and a pointer to the `cleanup-test-fixtures` skill for building a fake folder.

### 7. CI: `.github/workflows/ci.yml`
```yaml
name: CI
on:
  push:         { branches: [main] }
  pull_request: { branches: [main] }
permissions: { contents: read }
jobs:
  build-and-test:
    runs-on: xcode-27          # preview image; the only hosted image with Xcode 27
    steps:
      - uses: actions/checkout@v7
      - run: sudo xcode-select -s /Applications/Xcode_27.2.app && xcodebuild -version
      - run: brew install xcodegen
      - run: xcodegen generate
      - run: xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' -derivedDataPath build build CODE_SIGNING_ALLOWED=NO
      - run: xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' -derivedDataPath build test  CODE_SIGNING_ALLOWED=NO
```
Report to the owner: image `xcode-27`, Xcode 27.2 (27B52), preview status, may queue slower than GA images.

### 8. Verify (mac-app-build-verify skill)
1. `xcodegen generate`
2. `xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' -derivedDataPath build build 2>&1 | tail -40` → zero errors, zero warnings (warnings are already errors via the settings, so a clean build proves it).
3. `xcodebuild ... test 2>&1 | tail -60` → 7 tests pass.
4. `open build/Build/Products/Debug/SmartOSFileStore.app` → window titled "Smart OS File Store" with the placeholder; confirm the process is alive (`pgrep -x SmartOSFileStore`), then quit it.
5. Also a Release build (`-configuration Release build`) to prove the `#if DEBUG` path compiles out without warnings. Optional but cheap.
6. If the build rewrote `Localizable.xcstrings`, keep the rewritten file.
Fix any failure at the cause and restart from step 1 of the skill.

### 9. Commit
```bash
git add -A && git commit -m "Set up project"
```
Precondition checked at execution time: `git config user.name` / `user.email` are set; if not, ask the owner. Confirm `git status --ignored` shows `build/`, `*.xcodeproj`, `buildServer.json`, `.DS_Store` ignored.

### 10. GitHub
gh is installed and signed in (`Quaden2307`, `repo` + `workflow` scopes), and the repo does not exist. **Stop and ask the owner** before running:
```bash
gh repo create smart-os-file-store --private --source . --remote origin --push
```
No push without an explicit yes.

---

## Files created
```
.claude/skills/mac-app-build-verify/SKILL.md
.claude/skills/cleanup-test-fixtures/SKILL.md
.claude/skills/add-cleanup-action/SKILL.md
.github/workflows/ci.yml
.gitignore
README.md
project.yml
plans/2026-11-12-set-up-project.md
SmartOSFileStore/SmartOSFileStoreApp.swift
SmartOSFileStore/ContentView.swift
SmartOSFileStore/Localizable.xcstrings
SmartOSFileStore/Info.plist            (generated by xcodegen, committed)
FileStoreCore/ScanLocation.swift
FileStoreCoreTests/ScanLocationTests.swift
```
Generated and ignored: `SmartOSFileStore.xcodeproj/`, `build/`, `buildServer.json`.

## Final report to the owner (per skill)
What changed, build result, test count/result, what was checked in the running app, the CI image and Xcode version chosen, the file list above, and hand-check steps:
- Open the app from `build/Build/Products/Debug/`; expect a window titled "Smart OS File Store" showing a folder icon, "No Files Yet" and the description line; switch light/dark mode and confirm system colours follow.
- In VS Code, open a Swift file and confirm the Swift extension shows no "could not find build server" error and jump-to-definition works (it uses `buildServer.json`).
- Check the GitHub Actions run after the first push (if the owner says yes to step 10).

## Risks / things that may need a judgment call during execution
- Xcode 27.2 with warnings-as-errors may surface a warning the plan cannot predict (missing app icon, string-catalog state, a new Swift 6.4 diagnostic). Rule: fix the cause; any annotation or flag used to silence must carry a comment explaining why it is safe.
- `xcode-27` is a preview image. If it is unavailable when the owner pushes, the fallback is `macos-26` with Xcode 26.6, which still supports deployment target 26.0, but that is the owner's call and would be reported, not done silently.
- If `xcodegen` rejects a key in the spec, adjust the key, not the requirement.
