import Foundation
import Combine

// MARK: - App State (staged beam flow)

// What the user picked in the Subtitles dropdown.
enum SubtitleChoice: Equatable {
    case none
    case embedded(index: Int, label: String)  // a text track already in the file
    case external(URL)                        // sidecar found nearby, or hand-picked

    var label: String {
        switch self {
        case .none: return "None"
        case .embedded(_, let label): return label
        case .external(let url): return url.lastPathComponent
        }
    }
}

final class AppState: ObservableObject {
    @Published var selectedFile: URL?
    @Published var subtitleChoice: SubtitleChoice = .none
    @Published var embeddedSubs: [(index: Int, label: String)] = []
    @Published var sidecarSubs: [URL] = []
    @Published var isProcessing = false
    @Published var statusText = ""
    // "1.4 GB · MP4" shown under the filename.
    @Published var fileDetail = ""
}

// Single-screen layout: file zone with subtitles on top, Play at the bottom.
// AirPlay device selection happens in the native player (its AirPlay button) —
