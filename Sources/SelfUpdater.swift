import AppKit
import CryptoKit

/// Installs a new version in place: downloads the release archive from this repository's GitHub release, checks it
/// against the SHA-256 GitHub publishes for it, checks that what's inside really is this app at the announced
/// version with an intact signature, and then lets a small shell script swap the bundle once the app has quit and
/// start the new copy.
///
/// The builds are self-signed (no Developer ID), so there is no signature chain to rely on: the trust comes from
/// HTTPS to github.com, the repository's release, and the published checksum. macOS may ask for the
/// Automation / Screen Recording permissions again after an update, because each build's ad-hoc signature differs.
final class SelfUpdater: NSObject, URLSessionDownloadDelegate {
    enum Phase {
        case downloading(Double)
        case verifying
        case installing
    }

    private struct Failure: Error { var message: String }

    var onPhase: ((Phase) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var isBusy = false

    private var release: UpdateChecker.Release?
    private var workDirectory: URL?
    private var session: URLSession?

    // MARK: - Can it be done here?

    /// Why an in-place update isn't possible for this copy of the app, or nil when it is.
    static func blocker(for release: UpdateChecker.Release) -> String? {
        guard release.archive != nil, release.sha256 != nil else {
            return L("This release has no verified download — open the release page to update.")
        }
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { return L("DynamicIsland isn't running as an app bundle.") }
        let folder = app.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("build.sh").path) {
            return L("This is a development build — rebuild it with ./build.sh.")
        }
        guard FileManager.default.isWritableFile(atPath: folder.path),
              FileManager.default.isWritableFile(atPath: app.path) else {
            return L("DynamicIsland can't change its own folder. Update it from the release page or move it to Applications.")
        }
        return nil
    }

    // MARK: - Download

    func install(_ release: UpdateChecker.Release) {
        guard !isBusy, let archive = release.archive, release.sha256 != nil else { return }
        isBusy = true
        self.release = release
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicIslandUpdate-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return fail(L("Couldn't prepare a folder for the update."))
        }
        workDirectory = directory
        onPhase?(.downloading(0))
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        self.session = session
        session.downloadTask(with: archive).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytes: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        onPhase?(.downloading(expected > 0 ? Double(written) / Double(expected) : 0))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let workDirectory else { return }
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            return fail(L("The download failed."))
        }
        let archive = workDirectory.appendingPathComponent("update.zip")
        do {
            try FileManager.default.moveItem(at: location, to: archive)
        } catch {
            return fail(L("Couldn't save the download."))
        }
        verifyAndInstall(archive)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, isBusy { fail(error.localizedDescription) }
    }

    // MARK: - Check and swap

    private func verifyAndInstall(_ archive: URL) {
        guard let release, let expected = release.sha256, let workDirectory else { return }
        onPhase?(.verifying)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard try Self.sha256(of: archive) == expected else {
                    throw Failure(message: L("The download doesn't match its published checksum, so it was discarded."))
                }
                let extracted = workDirectory.appendingPathComponent("extracted")
                guard Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path]) == 0 else {
                    throw Failure(message: L("Couldn't unpack the download."))
                }
                let app = extracted.appendingPathComponent("DynamicIsland.app")
                try Self.validate(app, version: release.version)
                DispatchQueue.main.async { self.swapAndRestart(newApp: app, in: workDirectory) }
            } catch let failure as Failure {
                DispatchQueue.main.async { self.fail(failure.message) }
            } catch {
                DispatchQueue.main.async { self.fail(error.localizedDescription) }
            }
        }
    }

    /// The SHA-256 of a file, as lowercase hex.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The unpacked app must be this app (same bundle identifier) at the announced version, with a runnable
    /// executable and a signature that verifies.
    static func validate(_ app: URL, version: String) throws {
        guard let bundle = Bundle(url: app), let info = bundle.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Failure(message: L("The download isn't the expected version of DynamicIsland."))
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw Failure(message: L("The downloaded app's signature is damaged."))
        }
        // If this copy is signed with a certificate, the update must be signed with the very same one. (A copy
        // with an ad-hoc signature — the first releases — has nothing to compare, so the update is accepted.)
        if let leaf = signingCertificateHash(of: Bundle.main.bundleURL) {
            guard run("/usr/bin/codesign", ["--verify", "-R", "=certificate leaf = H\"\(leaf)\"", app.path]) == 0 else {
                throw Failure(message: L("The download isn't signed by the same developer as this app."))
            }
        }
    }

    /// The SHA-1 of the certificate an app is signed with (from its designated requirement), if it has one.
    static func signingCertificateHash(of app: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "-r-", app.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: #"certificate leaf = H"([0-9a-fA-F]{40})""#, options: .regularExpression) else { return nil }
        let match = String(text[range])
        return String(match.dropFirst("certificate leaf = H\"".count).prefix(40)).lowercased()
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Hands the swap to a shell script that outlives the app: it waits for this process to quit, moves the old
    /// bundle aside, copies the new one in (putting the old one back if that fails) and opens the result.
    private func swapAndRestart(newApp: URL, in directory: URL) {
        onPhase?(.installing)
        let script = directory.appendingPathComponent("swap.sh")
        let text = """
            #!/bin/sh
            PID="$1"; NEW="$2"; APP="$3"; WORK="$4"; OLD="$APP.replaced-by-update"
            for i in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
            rm -rf "$OLD"
            mv "$APP" "$OLD" || { open "$APP"; exit 1; }
            if ditto "$NEW" "$APP"; then rm -rf "$OLD"; else rm -rf "$APP"; mv "$OLD" "$APP"; fi
            xattr -dr com.apple.quarantine "$APP" 2>/dev/null
            open "$APP"
            case "$WORK" in */DynamicIslandUpdate-*) rm -rf "$WORK" ;; esac
            """
        do {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            return fail(L("Couldn't prepare the installer."))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path,
                             Bundle.main.bundleURL.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return fail(L("Couldn't start the installer.")) }
        NSApp.terminate(nil)
    }

    private func fail(_ message: String) {
        session?.invalidateAndCancel()
        session = nil
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
        workDirectory = nil
        isBusy = false
        onFailure?(message)
    }
}
