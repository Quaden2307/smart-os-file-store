# Smart OS File Store

Smart OS File Store is a native macOS file browser that will replace Finder, starting with a self-cleaning Downloads folder. It lists what is in Downloads and, only when asked, proposes cleanups such as removing exact duplicates, shows a preview you can edit, and sends confirmed files to the Trash. It is built with Swift 6, SwiftUI and XcodeGen for macOS 26 on Apple silicon, with all file logic in the `FileStoreCore` framework and the app as a thin interface on top.

## Build, test and run

Requirements: Xcode 27 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
# Generate SmartOSFileStore.xcodeproj from project.yml (rerun after adding or moving files)
xcodegen generate

# Build
xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' -derivedDataPath build build

# Run the unit tests
xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' -derivedDataPath build test

# Launch the app
open build/Build/Products/Debug/SmartOSFileStore.app
```

## Hand testing against a fake folder

Debug builds can be pointed at a folder other than Downloads, so cleanup features are never tried on real files. Build a throwaway folder with the script in `.claude/skills/cleanup-test-fixtures/SKILL.md`, then launch the app with either of these. The launch argument wins when both are set. Release builds ignore both.

```bash
open build/Build/Products/Debug/SmartOSFileStore.app --args -ScanFolder /path/to/FakeDownloads

SMARTOS_SCAN_FOLDER=/path/to/FakeDownloads open build/Build/Products/Debug/SmartOSFileStore.app
```

## VS Code

After generating the project, bind the Swift extension to it so indexing and jump-to-definition work:

```bash
xcode-build-server config -scheme SmartOSFileStore -project SmartOSFileStore.xcodeproj
```

This writes `buildServer.json`, which holds local paths and is not committed.
