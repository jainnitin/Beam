import AppKit
import AVKit
import AVFoundation
import CoreMedia

// MARK: - Player Window

// Hosts the AVPlayerView and accepts a dragged-in subtitle file so the user can
// attach captions to whatever is currently playing.
class SubtitleDropView: NSView {
    var onSubtitleDropped: ((URL) -> Void)?
    private let subtitleExts: Set<String> = ["srt", "vtt", "ass", "ssa"]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    private func subtitleURL(from sender: NSDraggingInfo) -> URL? {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        return urls?.first { subtitleExts.contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return subtitleURL(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = subtitleURL(from: sender) else { return false }
        DispatchQueue.main.async { [weak self] in self?.onSubtitleDropped?(url) }
        return true
    }
}

// Static helpers for the in-window player (Beam is a single-window app: the
// main window's content swaps between the library UI and the player).
enum PlayerSupport {
    // Override the default tx3g/mov_text look: drop the opaque black box behind
    // captions (transparent background) and add a drop shadow so the text stays
    // legible over bright scenes.
    static func subtitleStyleRules() -> [AVTextStyleRule] {
        guard let rule = AVTextStyleRule(textMarkupAttributes: [
            kCMTextMarkupAttribute_BackgroundColorARGB as String: [0.0, 0.0, 0.0, 0.0],
            kCMTextMarkupAttribute_CharacterEdgeStyle as String:
                kCMTextMarkupCharacterEdgeStyle_DropShadow as String,
        ]) else {
            return []
        }
        return [rule]
    }

    static func makePlayerItem(url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        item.textStyleRules = subtitleStyleRules()
        return item
    }

}

