import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Drop Zone View
class DropZoneNSView: NSView {
    var onFileSelected: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pboard = sender.draggingPasteboard
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let first = urls.first {
            let targetURL = first
            DispatchQueue.main.async { [weak self] in
                self?.onFileSelected?(targetURL)
            }
            return true
        }
        return false
    }
}

struct DropZoneRepresentable: NSViewRepresentable {
    var onFileSelected: (URL) -> Void

    func makeNSView(context: Context) -> DropZoneNSView {
        let view = DropZoneNSView()
        view.onFileSelected = onFileSelected
        return view
    }

    func updateNSView(_ nsView: DropZoneNSView, context: Context) {}
}
struct BeamHomeView: View {
    @ObservedObject var state: AppState
    var onFileSelected: (URL) -> Void
    var onPickSubtitle: () -> Void
    var onBeam: () -> Void
    var onRemoveFile: () -> Void

    private let brandPurple = Color(red: 0.55, green: 0.20, blue: 0.60)
    private let supportedFormats = ["MP4", "MKV", "M4V", "MOV", "AVI"]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.06, blue: 0.12), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Whole window is a drop target (behind the content, so buttons
            // still receive their own clicks).
            DropZoneRepresentable(onFileSelected: onFileSelected)

            VStack(alignment: .leading, spacing: 22) {
                header

                fileSection

                Spacer(minLength: 0)

                hintLine

                beamBar
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 24)
        }
    }

    // MARK: File section

    private var fileSection: some View {
        Group {
            if state.selectedFile == nil {
                emptyFileZone
            } else {
                loadedFileCard
            }
        }
    }

    private var emptyFileZone: some View {
        ZStack {
            rippleRings
            VStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(brandPurple)
                    .frame(width: 58, height: 58)
                    .background(Circle().strokeBorder(brandPurple.opacity(0.6), lineWidth: 1.5))
                Text("Drop a video here")
                    .font(.title3.weight(.semibold))
                Text(supportedFormats.joined(separator: " · "))
                    .font(.caption).foregroundColor(.secondary)
                Button(action: { selectFileViaPanel() }) {
                    Text("Choose Video…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18).padding(.vertical, 7)
                        .background(Capsule().fill(brandPurple))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 188)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
                .foregroundColor(brandPurple.opacity(0.5))
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.03)))
        )
    }

    // Horizontal card: artwork-style icon on the left, metadata on the right —
    // no centered text, so nothing looks cramped.
    private var loadedFileCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(brandPurple.opacity(0.18))
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: "film")
                            .font(.system(size: 22))
                            .foregroundColor(brandPurple)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(state.selectedFile?.lastPathComponent ?? "")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(state.fileDetail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 8)

                Button("Change…") { selectFileViaPanel() }
                    .buttonStyle(.link)
                    .font(.subheadline)

                Button(action: { onRemoveFile() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove this video")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().opacity(0.5)

            // Subtitles row: label column + control, macOS form style.
            HStack(spacing: 12) {
                Text("Subtitles")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(width: 68, alignment: .leading)
                subtitleMenu
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        )
    }

    // Subtitles dropdown: None, any text tracks inside the file, any sidecar
    // files found next to it, plus "Select External…". No online search.
    private var subtitleMenu: some View {
        HStack(spacing: 6) {
            Menu {
                Button {
                    state.subtitleChoice = .none
                } label: {
                    Label("None", systemImage: state.subtitleChoice == .none ? "checkmark" : "")
                }

                if !state.embeddedSubs.isEmpty {
                    Divider()
                    ForEach(state.embeddedSubs, id: \.index) { sub in
                        Button {
                            state.subtitleChoice = .embedded(index: sub.index, label: sub.label)
                        } label: {
                            Text(sub.label)
                        }
                    }
                }

                if !state.sidecarSubs.isEmpty {
                    Divider()
                    ForEach(state.sidecarSubs, id: \.self) { url in
                        Button {
                            state.subtitleChoice = .external(url)
                        } label: {
                            Text(url.lastPathComponent)
                        }
                    }
                }

                Divider()
                Button("Select External…") { onPickSubtitle() }
            } label: {
                Text(state.subtitleChoice.label)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 260, alignment: .leading)
        }
    }

    // MARK: Play bar

    private var beamBar: some View {
        Group {
            if state.isProcessing {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.6).frame(width: 18, height: 18)
                    Text(state.statusText.isEmpty ? "Preparing…" : state.statusText)
                        .font(.subheadline).foregroundColor(.secondary)
                    Spacer()
                }
                .frame(height: 44)
            } else {
                let disabled = state.selectedFile == nil
                Button(action: { onBeam() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("Play")
                    }
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 11)
                        .fill(disabled ? Color.gray.opacity(0.3) : brandPurple))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .help(disabled ? "Choose a video first" : "Open the player — pick your Apple TV from its AirPlay button")
            }
        }
    }

    // One honest line about where AirPlay selection happens.
    private var hintLine: some View {
        HStack(spacing: 7) {
            Image(systemName: "airplayvideo")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("To beam, hover over the video and click the AirPlay button, then pick your Apple TV. Esc comes back here.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Concentric AirPlay "waves" glyph to match the app icon.
            Image(systemName: "airplayaudio")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.linearGradient(colors: [.pink, brandPurple],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("Beam")
                .font(.title).bold()
        }
    }

    private var rippleRings: some View {
        ZStack {
            ForEach(0..<4) { i in
                Circle()
                    .strokeBorder(brandPurple.opacity(0.18), lineWidth: 1)
                    .frame(width: CGFloat(140 + i * 120), height: CGFloat(140 + i * 120))
            }
        }
        .allowsHitTesting(false)
    }

    private var formatBar: some View {
        HStack(spacing: 8) {
            Text("Supported:")
                .font(.caption)
                .foregroundColor(.secondary)
            ForEach(supportedFormats, id: \.self) { fmt in
                Text(fmt)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
        }
    }

    private func selectFileViaPanel() {
        let panel = NSOpenPanel()
        panel.title = "Select Video File"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            let targetURL = url
            DispatchQueue.main.async {
                onFileSelected(targetURL)
            }
        }
    }
}

