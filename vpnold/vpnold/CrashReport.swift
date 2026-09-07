import Foundation

// Detects an unclean shutdown and preserves the log that led up to it.
// Same shape as tvold's CrashReport: a session flag that only an orderly exit
// clears, and a log rotated aside at launch so the dead run's copy survives to
// be shown. Added here: crash_trap.c writes a real backtrace on the way down,
// and uncaught ObjC exceptions are recorded with their reason.
final class CrashReport {
    private static let runningKey = "vpnold.sessionRunning"
    // Set once an unclean run's log has been preserved, cleared once it has
    // been handed to the UI. Survives relaunches, unlike runningKey.
    private static let unshownKey = "vpnold.reportUnshown"

    private(set) static var crashedLastRun = false

    private static var docs: NSString {
        let dirs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        return (dirs.first ?? NSTemporaryDirectory()) as NSString
    }
    private static var currentPath: String { docs.appendingPathComponent("crash.log") }
    private static var previousPath: String { docs.appendingPathComponent("crash-previous.log") }

    static func beginSession() {
        crashedLastRun = UserDefaults.standard.bool(forKey: runningKey)

        let fm = FileManager.default
        // Never rotate on top of an unclean run's log that nobody has read yet:
        // a crash loop would grind the one interesting log out of existence.
        let hold = UserDefaults.standard.bool(forKey: unshownKey)
            && fm.fileExists(atPath: previousPath)
        if fm.fileExists(atPath: currentPath) {
            if hold {
                try? fm.removeItem(atPath: currentPath)
            } else {
                try? fm.removeItem(atPath: previousPath)
                try? fm.moveItem(atPath: currentPath, toPath: previousPath)
            }
        }
        if crashedLastRun { UserDefaults.standard.set(true, forKey: unshownKey) }
        markRunning(true)

        crash_trap_install(currentPath)
        // Runs in normal context (not a signal handler), so Foundation is fine
        // here and we get the exception's reason — the most useful line there is.
        NSSetUncaughtExceptionHandler { exception in
            CrashReport.note("=== UNCAUGHT EXCEPTION: \(exception.name.rawValue)")
            CrashReport.note("reason: \(exception.reason ?? "(none)")")
            for frame in exception.callStackSymbols { CrashReport.note(frame) }
            CrashReport.note("=== end of exception ===")
        }

        note("--- launch: previous run "
             + (crashedLastRun ? "ENDED UNCLEANLY" : "exited cleanly"))
    }

    static func note(_ line: String) { crash_trap_note(line) }

    /// Breadcrumb: the last one in the log is where the app was when it died.
    static func stage(_ name: String) { note("stage: \(name)") }

    // Backgrounding counts as orderly — iOS may evict a backgrounded app for
    // its own reasons, and that is not a crash.
    static func endSession() { note("--- clean exit"); markRunning(false) }
    static func resumeSession() { markRunning(true) }

    private static func markRunning(_ running: Bool) {
        UserDefaults.standard.set(running, forKey: runningKey)
        UserDefaults.standard.synchronize()
    }

    /// Hands the preserved log over and clears the pending flag in the same
    /// step — clearing before anything is drawn, so that a crash on the
    /// reporting path itself cannot turn into a launch-time crash loop.
    static func takeReport() -> String? {
        guard UserDefaults.standard.bool(forKey: unshownKey) else { return nil }
        UserDefaults.standard.set(false, forKey: unshownKey)
        UserDefaults.standard.synchronize()

        guard let text = try? String(contentsOfFile: previousPath, encoding: .utf8),
              !text.isEmpty else {
            return "(the previous run ended uncleanly but left no log)"
        }
        return text
    }
}
