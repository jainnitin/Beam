import AppKit
import Foundation

// MARK: - Self-updater (GitHub Releases)

// Lightweight updater: compares the running version against the latest GitHub
// release, downloads the arch-specific zip, and swaps the app in place. No
// dependencies. Releases are ad-hoc signed, so the swap strips the download
// quarantine so the new build launches without a Gatekeeper prompt.
final class AppUpdater: NSObject, URLSessionDownloadDelegate {
    private let owner = "jainnitin"
    private let repo = "Beam"

    // Single universal build shipped by the release workflow.
    private let assetName = "Beam.zip"

    // Download UI/state. The progress window is deliberately NON-modal: a nested
    // modal run loop would starve URLSession's delegate callbacks, which is what
    // made an earlier version appear to hang mid-download.
    private var progressWindow: NSWindow?
    private var progressBar: NSProgressIndicator?
    private var downloadTask: URLSessionDownloadTask?
    private var installing = false

    private var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    func checkForUpdates(userInitiated: Bool) {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Beam-Updater", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 404 means the repo simply has no published release yet — that's
            // "nothing newer," not a failure.
            if status == 404 {
                if userInitiated {
                    DispatchQueue.main.async { self.upToDate() }
                }
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                if userInitiated {
                    DispatchQueue.main.async {
                        self.alert("Couldn't check for updates",
                                   error?.localizedDescription ?? "Please try again later.")
                    }
                }
                return
            }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = (json["assets"] as? [[String: Any]]) ?? []
            let downloadURL = assets.first { ($0["name"] as? String) == self.assetName }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap { URL(string: $0) }

            DispatchQueue.main.async {
                guard Self.isNewer(latest, than: self.currentVersion) else {
                    if userInitiated { self.upToDate() }
                    return
                }
                guard let downloadURL else {
                    if userInitiated {
                        self.alert("Update available",
                                   "Beam \(latest) is available, but no build for this Mac was found. Download it from the releases page.")
                    }
                    return
                }
                self.promptAndInstall(version: latest, downloadURL: downloadURL)
            }
        }.resume()
    }

    private func upToDate() {
        alert("You're up to date", "Beam \(currentVersion) is the latest version.")
    }

    private var releasesPageURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases")!
    }

    private func promptAndInstall(version: String, downloadURL: URL) {
        let alert = NSAlert()
        alert.messageText = "A new version of Beam is available"
        alert.informativeText = "Beam \(version) is available. Install it now?"
        alert.addButton(withTitle: "Install Now")
        alert.addButton(withTitle: "What's New")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertSecondButtonReturn:                 // What's New → open releases page, re-ask
            NSWorkspace.shared.open(releasesPageURL)
            promptAndInstall(version: version, downloadURL: downloadURL)
            return
        case .alertFirstButtonReturn:                  // Install Now
            break
        default:                                       // Later
            return
        }

        startDownload(version: version, downloadURL: downloadURL)
    }

    // MARK: Non-modal, delegate-driven download

    private func startDownload(version: String, downloadURL: URL) {
        installing = false
        showProgressWindow(version: version)

        // delegateQueue = .main so progress/finish callbacks run on the main
        // thread; the window is non-modal, so the run loop delivers them.
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        let task = session.downloadTask(with: downloadURL)
        downloadTask = task
        task.resume()
    }

    private func showProgressWindow(version: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 118),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Updating Beam"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentView!.bounds)

        let label = NSTextField(labelWithString: "Downloading Beam \(version)…")
        label.frame = NSRect(x: 20, y: 72, width: 340, height: 18)
        content.addSubview(label)

        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 46, width: 340, height: 16))
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1
        content.addSubview(bar)
        progressBar = bar

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelDownload))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 276, y: 10, width: 88, height: 28)
        content.addSubview(cancel)

        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        progressWindow = window
    }

    private func closeProgressWindow() {
        progressWindow?.close()
        progressWindow = nil
        progressBar = nil
        downloadTask = nil
    }

    @objc private func cancelDownload() {
        downloadTask?.cancel()
        closeProgressWindow()
    }

    // MARK: URLSessionDownloadDelegate (called on the main queue)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressBar?.doubleValue = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // `location` is deleted when this method returns, so move it out now.
        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent("Beam-update-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: stable)
        } catch {
            closeProgressWindow()
            alert("Update failed", error.localizedDescription)
            return
        }
        installing = true
        closeProgressWindow()
        installUpdate(zipTemp: stable)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, !installing else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }   // user hit Cancel
        closeProgressWindow()
        alert("Download failed", error.localizedDescription)
    }

    private func installUpdate(zipTemp: URL) {
        let fm = FileManager.default
        let bundlePath = Bundle.main.bundlePath  // e.g. /Applications/Beam.app
        let work = fm.temporaryDirectory.appendingPathComponent("beam-update-\(UUID().uuidString)")
        let zip = work.appendingPathComponent("Beam.zip")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try fm.moveItem(at: zipTemp, to: zip)

            // Unzip with ditto (handles the macOS archive format the release uses).
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zip.path, work.path]
            try unzip.run(); unzip.waitUntilExit()

            let newApp = work.appendingPathComponent("Beam.app")
            guard fm.fileExists(atPath: newApp.path) else {
                alert("Update failed", "The downloaded archive didn't contain Beam.app.")
                return
            }

            // Hand off to a detached script: wait for us to quit, swap the bundle,
            // strip quarantine, relaunch.
            let script = work.appendingPathComponent("swap.sh")
            let body = """
            #!/bin/bash
            while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
            /bin/rm -rf "\(bundlePath)"
            /usr/bin/ditto "\(newApp.path)" "\(bundlePath)"
            /usr/bin/xattr -dr com.apple.quarantine "\(bundlePath)"
            /usr/bin/open "\(bundlePath)"
            /bin/rm -rf "\(work.path)"
            """
            try body.write(to: script, atomically: true, encoding: .utf8)

            let run = Process()
            run.executableURL = URL(fileURLWithPath: "/bin/bash")
            run.arguments = [script.path]
            try run.run()

            NSApp.terminate(nil)
        } catch {
            alert("Update failed", error.localizedDescription)
        }
    }

    // Numeric semver compare (e.g. "1.2.0" > "1.10.0" is false).
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
