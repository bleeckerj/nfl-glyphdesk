import AppKit
import Darwin
import os

@main
@MainActor
enum GlyphDeskLaunch {
    static func main() {
        guard let identifier = Bundle.main.bundleIdentifier else {
            NSLog("Glyph Desk is missing its bundle identifier.")
            exit(EXIT_FAILURE)
        }
        let lockURL = Preferences.url.deletingLastPathComponent()
            .appendingPathComponent("\(identifier).instance.lock")
        do {
            guard let lock = try ApplicationInstanceLock.acquire(at: lockURL) else {
                reopenRunningApplication(identifier: identifier, includeLaunching: true)
                return
            }
            // An older build can already be running without holding the lock.
            guard !reopenRunningApplication(identifier: identifier, includeLaunching: false) else { return }
            withExtendedLifetime(lock) { GlyphDeskApp.main() }
        } catch {
            Logger(subsystem: identifier, category: "Launch").error(
                "Could not claim the Glyph Desk launch lock: \(error.localizedDescription, privacy: .public)"
            )
            exit(EXIT_FAILURE)
        }
    }

    @discardableResult
    private static func reopenRunningApplication(identifier: String, includeLaunching: Bool) -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: {
            $0.processIdentifier != currentPID && !$0.isTerminated && (includeLaunching || $0.isFinishedLaunching)
        }) else { return false }
        if let url = app.bundleURL, NSWorkspace.shared.open(url) { return true }
        app.activate()
        return true
    }
}

final class ApplicationInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(at url: URL) throws -> ApplicationInstanceLock? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return ApplicationInstanceLock(descriptor: descriptor) }

        let error = errno
        close(descriptor)
        if error == EWOULDBLOCK { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
    }

    // Keep the file in place so every launch locks the same file, even across quits.
    deinit { close(descriptor) }
}
