import os

/// Unified-log lines so a report like "the icon did not show" can be diagnosed afterwards.
/// Nothing private is logged: never a key, never dictated text (only lengths and timings).
///
/// Read them with:
///   log show --predicate 'subsystem == "com.davidfinnegan.lavalier"' --last 1h --info
enum Log {
    static let subsystem = "com.davidfinnegan.lavalier"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let dictation = Logger(subsystem: subsystem, category: "dictation")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
}
