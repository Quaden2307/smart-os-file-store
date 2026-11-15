import Foundation

/// Why the activity log could not be opened, read or written. Each case has a message in the app's
/// words. Cleanup never runs without a working log, so every case stops it.
public enum ActivityLogError: Error, Sendable, Hashable {
    /// The file is not a database, or SQLite's own check found damage in it. The app offers to
    /// start a fresh log and keep this file aside.
    case damaged

    /// The database, or its folder, could not be opened, made or read: no permission, a full disk,
    /// a link or a folder where the file should be. `code` is SQLite's result code or the `errno`
    /// value, for logs.
    case unreadable(code: Int32)

    /// The database was written by a newer version of the app, which this version must not change.
    case newerVersion

    /// A write failed while the log was in use: a full disk, a file another copy of the app holds
    /// locked, an I/O error. `code` is SQLite's result code, for logs.
    case writeFailed(code: Int32)

    /// The log no longer holds a row the executor wrote a moment ago, so it cannot be trusted to
    /// describe the run.
    case inconsistent

    /// The folder the log belongs in could not be worked out: no Application Support folder, or
    /// an app identifier that is not one folder name.
    case locationUnavailable
}
