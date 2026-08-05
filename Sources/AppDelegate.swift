import SwiftUI
import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Pure AppKit Application Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    // Shared player for local ("This Mac") playback; its in-player AirPlay
    // button remains available for system routing.
    let sharedPlayer: AVPlayer = {
        let p = AVPlayer()
        p.allowsExternalPlayback = true
        return p
    }()

    let appState = AppState()

    // Single window; its content swaps between the library UI and the player.
    var mainWindow: NSWindow?
    private var libraryHost: NSHostingView<BeamHomeView>?
    private var playerContainer: SubtitleDropView?
    private var isShowingPlayer = false
    private var currentPlayTitle = ""
    // The original video currently loaded (not the optimized temp file), so a
    // subtitle can be added/changed and the pipeline re-run against it.
    private var currentOriginalURL: URL?
    // AVPlayer.isExternalPlaybackActive flips true once video is on a TV.
    private var externalPlaybackObservation: NSKeyValueObservation?
    // Escape returns from the player to the library.
    private var escKeyMonitor: Any?
    let updater = AppUpdater()

    func applicationWillFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        let args = CommandLine.arguments
        if args.count > 1 {
            stageFile(url: URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // From Apple's long-form video AirPlay guidance: track external
        // playback state so the UI reflects when video is actually on the TV.
        // Fires when a device is picked from the player's AirPlay button and
        // when playback returns to the Mac.
        externalPlaybackObservation = sharedPlayer.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
            let active = player.isExternalPlaybackActive
            DispatchQueue.main.async {
                guard let self, self.isShowingPlayer else { return }
                self.mainWindow?.title = active
                    ? "Beam — \(self.currentPlayTitle) ▸ Apple TV"
                    : "Beam — \(self.currentPlayTitle)"
            }
        }

        // Escape backs out of the player to the library (no overlay button —
        // it would collide with the native controls). In full screen, Escape
        // keeps its system meaning and exits full screen first.
        escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.keyCode == 53, // Escape
                  self.isShowingPlayer,
                  self.mainWindow?.styleMask.contains(.fullScreen) != true else {
                return event
            }
            self.showLibrary()
            return nil // consumed
        }

        showLandingWindow()

        // Silent update check shortly after launch; only speaks up if an update
        // exists. Manual check is in the Beam menu.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.updater.checkForUpdates(userInitiated: false)
        }
    }

    @objc private func checkForUpdatesClicked() {
        updater.checkForUpdates(userInitiated: true)
    }

    // Quitting the last window quits the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // Pure-AppKit apps get no menu bar for free, so build a minimal one that
    // includes the standard Quit (⌘Q), Open (⌘O), Close (⌘W), and edit items.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application menu (its title is auto-replaced with the app name).
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Beam",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Check for Updates…",
                        action: #selector(checkForUpdatesClicked), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Beam",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Beam",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // File menu.
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…",
                         action: #selector(openDocument), keyEquivalent: "o")
        let openWithSub = fileMenu.addItem(withTitle: "Open Video with Subtitle…",
                         action: #selector(openDocumentWithSubtitle), keyEquivalent: "o")
        openWithSub.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Add / Change Subtitle…",
                         action: #selector(addSubtitleToCurrent), keyEquivalent: "t")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        // Edit menu (standard clipboard items, useful for the seek fields etc.).
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // Window menu.
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func openDocument() {
        if let url = runVideoOpenPanel() {
            stageFile(url: url)
        }
    }

    @objc private func openDocumentWithSubtitle() {
        guard let url = runVideoOpenPanel() else { return }
        // Subtitle is optional — Cancel just stages the video with auto-detection.
        let sub = runSubtitleOpenPanel(videoName: url.lastPathComponent)
        stageFile(url: url, subtitleURL: sub)
    }

    @objc private func addSubtitleToCurrent() {
        // Staged on the landing screen: just update the dropdown selection.
        if appState.selectedFile != nil, currentOriginalURL == nil {
            chooseExternalSubtitle()
            return
        }
        guard let video = currentOriginalURL else {
            let alert = NSAlert()
            alert.messageText = "No video open"
            alert.informativeText = "Open a video first, then add a subtitle to it."
            alert.runModal()
            return
        }
        if let sub = runSubtitleOpenPanel(videoName: video.lastPathComponent) {
            playLocally(url: video, subtitleURL: sub)
        }
    }

    // Items only make sense once a video is staged or playing.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(addSubtitleToCurrent) {
            return currentOriginalURL != nil || appState.selectedFile != nil
        }
        return true
    }

    // MARK: File staging

    // Clear the staged video and all state derived from it, returning the
    // library to the empty drop zone.
    func removeStagedFile() {
        appState.selectedFile = nil
        appState.subtitleChoice = .none
        appState.embeddedSubs = []
        appState.sidecarSubs = []
        appState.fileDetail = ""
        appState.isProcessing = false
        currentOriginalURL = nil
    }

    // A chosen/dropped/Finder-opened file lands here: stage it in the library
    // view (stopping any current playback) and populate subtitle options.
    func stageFile(url: URL, subtitleURL: URL? = nil) {
        showLibrary()
        appState.selectedFile = url
        appState.isProcessing = false
        appState.fileDetail = Self.fileDetail(for: url)
        loadSubtitleOptions(for: url, preselect: subtitleURL)
        showLandingWindow()
    }

    private func runVideoOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Select Video File"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func runSubtitleOpenPanel(videoName: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Select Subtitle for \(videoName)"
        panel.message = "Choose an SRT / VTT / ASS subtitle file (optional)."
        panel.prompt = "Choose Subtitle"
        let subTypes = ["srt", "vtt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) }
        if !subTypes.isEmpty {
            panel.allowedContentTypes = subTypes
        }
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        stageFile(url: URL(fileURLWithPath: filename))
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let first = filenames.first {
            stageFile(url: URL(fileURLWithPath: first))
        }
    }

    func showLandingWindow() {
        if mainWindow != nil {
            mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Single state-driven hosting view; SwiftUI re-renders on AppState
        // changes, so the library content view is created once.
        let homeView = BeamHomeView(
            state: appState,
            onFileSelected: { [weak self] url in self?.stageFile(url: url) },
            onPickSubtitle: { [weak self] in self?.chooseExternalSubtitle() },
            onBeam: { [weak self] in self?.beamButtonPressed() },
            onRemoveFile: { [weak self] in self?.removeStagedFile() }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Beam"
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: homeView)
        window.contentView = host
        // Keep the layout from being squeezed below a usable size.
        window.minSize = NSSize(width: 560, height: 460)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.libraryHost = host
        self.mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Single-window content swap (library <-> player)

    // Show the player inside the main window.
    private func switchToPlayer(url: URL, title: String) {
        guard let window = mainWindow else { return }
        sharedPlayer.replaceCurrentItem(with: PlayerSupport.makePlayerItem(url: url))

        if playerContainer == nil {
            let dropHost = SubtitleDropView(frame: window.contentView?.bounds ?? .zero)
            dropHost.autoresizingMask = [.width, .height]

            // AVPlayerView provides the native AirPlay button in its inline
            // controls — the mechanism that actually routes video to a TV.
            let playerView = AVPlayerView()
            playerView.player = sharedPlayer
            playerView.controlsStyle = .inline
            playerView.showsFrameSteppingButtons = false
            playerView.showsSharingServiceButton = false
            playerView.showsFullScreenToggleButton = true
            playerView.frame = dropHost.bounds
            playerView.autoresizingMask = [.width, .height]
            dropHost.addSubview(playerView)

            dropHost.onSubtitleDropped = { [weak self] subURL in
                guard let video = self?.currentOriginalURL else { return }
                self?.playLocally(url: video, subtitleURL: subURL)
            }
            playerContainer = dropHost
        }

        currentPlayTitle = title
        window.contentView = playerContainer
        window.title = "Beam — \(title)"
        isShowingPlayer = true
        sharedPlayer.play()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Return the main window to the library UI, stopping playback (which also
    // drops any active AirPlay route).
    func showLibrary() {
        sharedPlayer.pause()
        sharedPlayer.replaceCurrentItem(with: nil)
        guard isShowingPlayer, let window = mainWindow, let host = libraryHost else { return }
        window.contentView = host
        window.title = "Beam"
        isShowingPlayer = false
    }


    // "1.4 GB · MP4" for the file card.
    private static func fileDetail(for url: URL) -> String {
        let ext = url.pathExtension.uppercased()
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return ext }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(size))) · \(ext)"
    }

    // MARK: Subtitle options

    // Populate the Subtitles dropdown: text tracks inside the file (via
    // AVAsset, no ffprobe needed) plus sidecar files sitting next to it.
    private func loadSubtitleOptions(for url: URL, preselect: URL?) {
        appState.embeddedSubs = []
        appState.sidecarSubs = []
        appState.subtitleChoice = .none

        // Sidecars: same base name, subtitle extension.
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        let subExts: Set<String> = ["srt", "vtt", "ass", "ssa"]
        if let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let matches = entries.filter { f in
                guard subExts.contains(f.pathExtension.lowercased()) else { return false }
                let stem = f.deletingPathExtension().lastPathComponent.lowercased()
                return stem == base || stem.hasPrefix(base + ".")
            }.sorted { $0.lastPathComponent.count < $1.lastPathComponent.count }
            appState.sidecarSubs = matches
        }

        if let pre = preselect {
            appState.subtitleChoice = .external(pre)
            if !appState.sidecarSubs.contains(pre) { appState.sidecarSubs.insert(pre, at: 0) }
        }

        // Embedded text tracks.
        let asset = AVURLAsset(url: url)
        let state = appState
        Task {
            guard let group = try? await asset.loadMediaSelectionGroup(for: .legible) else { return }
            let found: [(index: Int, label: String)] = group.options.enumerated().map { i, option in
                let name = option.displayName
                return (index: i, label: name.isEmpty ? "Track \(i + 1)" : name)
            }
            await MainActor.run {
                state.embeddedSubs = found
                // Prefer an embedded track when nothing else was chosen, matching
                // the "default subtitle from the file" case.
                if state.subtitleChoice == .none, state.sidecarSubs.isEmpty,
                   let first = found.first {
                    state.subtitleChoice = .embedded(index: first.index, label: first.label)
                }
            }
        }
    }

    // The dropdown's "Select External…" item.
    func chooseExternalSubtitle() {
        guard let video = appState.selectedFile ?? currentOriginalURL else { return }
        if let sub = runSubtitleOpenPanel(videoName: video.lastPathComponent) {
            if !appState.sidecarSubs.contains(sub) { appState.sidecarSubs.insert(sub, at: 0) }
            appState.subtitleChoice = .external(sub)
        }
    }

    // MARK: Play action

    // Only an external file needs to be muxed in; embedded tracks are already
    // in the container, and .none means don't add anything.
    private var chosenSubtitleURL: URL? {
        if case .external(let url) = appState.subtitleChoice { return url }
        return nil
    }

    // Play opens the native player; beaming happens from the player's AirPlay
    // button (the only mechanism macOS lets an app route video through). Once
    // a TV is picked there, the isExternalPlaybackActive observer flips the
    // landing bar to "Beaming…".
    private func beamButtonPressed() {
        guard let file = appState.selectedFile else { return }
        playLocally(url: file, subtitleURL: chosenSubtitleURL)
    }

    private func showSimpleAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Preparation pipeline (remux + subtitles)

    // Remuxes to a playable MP4 via the bundled ffmpeg (RemuxEngine) off the main
    // queue, then calls back on the main queue with a playable file URL, or nil +
    // warning.
    private func prepareVideo(url: URL, subtitleURL: URL?,
                              completion: @escaping (URL?, String?) -> Void) {
        appState.isProcessing = true
        appState.statusText = "Preparing \(url.lastPathComponent)…"

        DispatchQueue.global(qos: .userInitiated).async {
            let result = RemuxEngine.prepare(input: url, subtitle: subtitleURL)
            DispatchQueue.main.async {
                if result.playable {
                    completion(result.file, result.warning)
                } else {
                    completion(nil, result.warning
                        ?? "Beam couldn't convert “\(url.lastPathComponent)” to a playable format.")
                }
            }
        }
    }

    // MARK: Local playback ("This Mac")

    func playLocally(url: URL, subtitleURL: URL? = nil) {
        currentOriginalURL = url
        prepareVideo(url: url, subtitleURL: subtitleURL) { [weak self] playURL, warning in
            guard let self else { return }
            self.appState.isProcessing = false
            if let playURL {
                self.switchToPlayer(url: playURL, title: url.lastPathComponent)
            } else {
                self.showSimpleAlert(title: "Couldn't play \(url.lastPathComponent)",
                                     message: warning ?? "Preparation failed.")
            }
        }
    }
}
