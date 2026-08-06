import Foundation
import CryptoKit

// Remuxes a source video into an Apple TV-compatible MP4 by stream-copying
// video/audio (no transcoding), tagging HEVC as hvc1, and embedding text
// subtitles (embedded or a chosen sidecar) as mov_text, using the bundled
// ffmpeg/ffprobe.
enum RemuxEngine {

    struct Result {
        let file: URL       // file to play (optimized, or the original on a no-op / failure)
        let playable: Bool  // true if `file` is an MP4-family container AVPlayer can play
        let warning: String?
    }

    // Text subtitle codecs that convert cheaply to MP4 mov_text.
    private static let textSubCodecs: Set<String> =
        ["subrip", "srt", "ass", "ssa", "mov_text", "text", "webvtt"]
    private static let sidecarExts: Set<String> = ["srt", "vtt", "ass", "ssa"]
    private static let playableExts: Set<String> = ["mp4", "m4v", "mov"]

    // Audio codecs the Apple TV can decode directly (stream-copy). Anything else
    // (DTS, TrueHD, FLAC, PCM, Opus…) plays silently on the TV, so it's
    // transcoded to AC-3 — cheap on CPU, and video is never re-encoded.
    private static let compatibleAudioCodecs: Set<String> =
        ["aac", "ac3", "eac3", "alac", "mp3"]

    // Bump when the ffmpeg recipe changes so stale cached outputs are rebuilt.
    private static let recipe = "r2-audio"

    // MARK: Binary discovery

    static func findFFmpeg() -> URL? { findBinary("ffmpeg") }
    static func findFFprobe() -> URL? { findBinary("ffprobe") }

    private static func findBinary(_ name: String) -> URL? {
        let fm = FileManager.default
        // Prefer the copy bundled in the app (Contents/Resources/<name>).
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent(name)
            if fm.isExecutableFile(atPath: bundled.path) { return bundled }
        }
        // Dev fallback: a system-installed ffmpeg (e.g. Homebrew).
        for dir in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"] {
            let candidate = URL(fileURLWithPath: dir + name)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: Public API

    static func prepare(input: URL, subtitle: URL?) -> Result {
        let fm = FileManager.default
        let src = input.standardizedFileURL
        guard fm.fileExists(atPath: src.path) else {
            return Result(file: input, playable: false, warning: "File not found: \(src.path)")
        }

        let ffmpeg = findFFmpeg()
        let ffprobe = findFFprobe()
        let ext = src.pathExtension.lowercased()

        // Inspect streams: is the video HEVC, is it mislabeled 'hev1', and which
        // subtitle tracks are text (convertible to mov_text)?
        var isHEVC = false
        var needsHvc1Fix = false
        var textSubIndices: [Int] = []
        // Audio tracks in file (map) order, so output audio stream i lines up
        // with audioStreams[i].
        var audioStreams: [(codec: String, channels: Int)] = []
        let streams = ffprobe.map { probe($0, src) } ?? []
        if !streams.isEmpty {
            for s in streams {
                let type = s.codec_type ?? ""
                let name = (s.codec_name ?? "").lowercased()
                let tag = (s.codec_tag_string ?? "").lowercased()
                if type == "video", name == "hevc" || name == "h265" {
                    isHEVC = true
                    if tag == "hev1" { needsHvc1Fix = true }
                } else if type == "audio" {
                    audioStreams.append((name, s.channels ?? 2))
                } else if type == "subtitle", textSubCodecs.contains(name) {
                    textSubIndices.append(s.index)
                }
            }
        } else if let data = try? FileHandle(forReadingFrom: src).readData(ofLength: 1_000_000),
                  data.range(of: Data("hev1".utf8)) != nil {
            // ffprobe unavailable: byte-scan for the 'hev1' tag that breaks Apple TV.
            isHEVC = true
            needsHvc1Fix = true
        }

        // An explicitly chosen subtitle wins over an auto-detected sidecar.
        var sidecar: URL? = nil
        if let sub = subtitle, fm.fileExists(atPath: sub.path) {
            sidecar = sub.standardizedFileURL
        } else {
            sidecar = findSidecarSubtitle(src)
        }

        let audioNeedsTranscode = audioStreams.contains { !compatibleAudioCodecs.contains($0.codec) }

        let containerOK = playableExts.contains(ext)
        // Nothing to do: already MP4-family, correctly tagged, no sidecar to add,
        // and all audio is Apple TV-compatible.
        if containerOK && !needsHvc1Fix && sidecar == nil && !audioNeedsTranscode {
            return Result(file: src, playable: true, warning: nil)
        }

        guard let ffmpeg else {
            return Result(file: src, playable: containerOK,
                          warning: containerOK ? nil
                            : "Could not convert this file to a playable MP4 container.")
        }

        // Cache: same source + subtitle -> reuse the finished MP4 instantly.
        let key = cacheKey(src, sidecar)
        let base = src.deletingPathExtension().lastPathComponent
        let tmp = fm.temporaryDirectory
        let output = tmp.appendingPathComponent("\(base)_\(key).mp4")
        if fm.fileExists(atPath: output.path) {
            return Result(file: output, playable: true, warning: nil)
        }
        let partial = tmp.appendingPathComponent("\(base)_\(key).part.mp4")
        try? fm.removeItem(at: partial)

        // Build the ffmpeg command: stream-copy A/V, convert text subs to mov_text.
        var args = ["-y", "-i", src.path]
        if let s = sidecar { args += ["-i", s.path] }
        args += ["-map", "0:v:0?", "-map", "0:a?"]

        var hasSubs = false
        if let _ = sidecar {
            args += ["-map", "1:0"]                          // sidecar replaces embedded
            hasSubs = true
        } else if ffprobe != nil && !streams.isEmpty {
            for i in textSubIndices { args += ["-map", "0:\(i)"] }
            hasSubs = !textSubIndices.isEmpty
        } else {
            args += ["-map", "0:s?"]                         // no probe info: best-effort
            hasSubs = true
        }

        args += ["-c:v", "copy"] + audioCodecArgs(audioStreams) + ["-dn", "-map_chapters", "-1"]
        if hasSubs {
            args += ["-c:s", "mov_text"]
            if let s = sidecar {
                let lang = inferSubLanguage(s) ?? "und"
                args += ["-metadata:s:s:0", "language=\(lang)",
                         "-metadata:s:s:0", "title=Subtitles",
                         "-disposition:s:0", "default"]
            }
        }
        if isHEVC { args += ["-tag:v", "hvc1"] }
        // No +faststart: the second pass doubles I/O, and local playback / the
        // Apple TV read a trailing moov fine.
        args += [partial.path]

        if run(ffmpeg, args), fm.fileExists(atPath: partial.path) {
            try? fm.removeItem(at: output)
            try? fm.moveItem(at: partial, to: output)
            return Result(file: output, playable: true, warning: nil)
        }

        // Subtitle muxing can occasionally fail; retry once without subtitles so
        // playback still works.
        if hasSubs {
            var fb = ["-y", "-i", src.path, "-map", "0:v:0?", "-map", "0:a?",
                      "-c:v", "copy"] + audioCodecArgs(audioStreams) + ["-dn", "-map_chapters", "-1"]
            if isHEVC { fb += ["-tag:v", "hvc1"] }
            fb += [partial.path]
            if run(ffmpeg, fb), fm.fileExists(atPath: partial.path) {
                try? fm.removeItem(at: output)
                try? fm.moveItem(at: partial, to: output)
                return Result(file: output, playable: true, warning: nil)
            }
        }

        try? fm.removeItem(at: partial)
        return Result(file: src, playable: containerOK,
                      warning: containerOK ? nil
                        : "Could not convert this file to a playable MP4 container.")
    }

    // MARK: ffprobe / ffmpeg execution

    private struct FFStream: Decodable {
        let index: Int
        let codec_type: String?
        let codec_name: String?
        let codec_tag_string: String?
        let channels: Int?
    }
    private struct FFProbeOutput: Decodable { let streams: [FFStream] }

    private static func probe(_ ffprobe: URL, _ input: URL) -> [FFStream] {
        let proc = Process()
        proc.executableURL = ffprobe
        proc.arguments = ["-v", "error",
                          "-show_entries", "stream=index,codec_type,codec_name,codec_tag_string,channels",
                          "-of", "json", input.path]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let decoded = try? JSONDecoder().decode(FFProbeOutput.self, from: data) else { return [] }
        return decoded.streams
    }

    private static func run(_ ffmpeg: URL, _ args: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = args
        // Discard ffmpeg output (progress on stderr) without a pipe that could
        // deadlock on volume.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    // MARK: Helpers

    // Per-output-audio-stream codec flags: copy Apple TV-compatible tracks,
    // transcode the rest to AC-3 (downmixing above 5.1, which the AC-3 encoder
    // can't exceed anyway). With no probe info, fall back to copying everything.
    private static func audioCodecArgs(_ audioStreams: [(codec: String, channels: Int)]) -> [String] {
        guard !audioStreams.isEmpty else { return ["-c:a", "copy"] }
        var args: [String] = []
        for (i, a) in audioStreams.enumerated() {
            if compatibleAudioCodecs.contains(a.codec) {
                args += ["-c:a:\(i)", "copy"]
            } else {
                args += ["-c:a:\(i)", "ac3", "-b:a:\(i)", "640k"]
                if a.channels > 6 { args += ["-ac:a:\(i)", "6"] }
            }
        }
        return args
    }

    private static func findSidecarSubtitle(_ video: URL) -> URL? {
        let dir = video.deletingLastPathComponent()
        let base = video.deletingPathExtension().lastPathComponent.lowercased()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return nil }
        let matches = entries.filter { f in
            guard sidecarExts.contains(f.pathExtension.lowercased()) else { return false }
            let stem = f.deletingPathExtension().lastPathComponent.lowercased()
            return stem == base || stem.hasPrefix(base + ".")
        }
        // Prefer the exact match, then the shortest (least language-tagged) name.
        return matches.sorted { $0.lastPathComponent.count < $1.lastPathComponent.count }.first
    }

    private static func cacheKey(_ input: URL, _ sidecar: URL?) -> String {
        func fingerprint(_ url: URL) -> String {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(url.path)|\(size)|\(Int64(mtime * 1_000_000_000))"
        }
        var parts = recipe + "|" + fingerprint(input)
        parts += "|" + (sidecar.map(fingerprint) ?? "nosub")
        let digest = SHA256.hash(data: Data(parts.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(10).description
    }

    // Infer an ISO 639-2 code from a subtitle filename suffix (e.g. Movie.en.srt),
    // so the muxed track is labelled ("English") instead of "Unknown language".
    private static let langAliases: [String: String] = [
        "en": "eng", "eng": "eng", "es": "spa", "spa": "spa", "fr": "fra", "fra": "fra",
        "fre": "fra", "de": "deu", "deu": "deu", "ger": "deu", "it": "ita", "ita": "ita",
        "pt": "por", "por": "por", "nl": "nld", "nld": "nld", "dut": "nld", "ru": "rus",
        "rus": "rus", "ja": "jpn", "jpn": "jpn", "ko": "kor", "kor": "kor", "zh": "zho",
        "zho": "zho", "chi": "zho", "hi": "hin", "hin": "hin", "ar": "ara", "ara": "ara",
        "sv": "swe", "swe": "swe", "pl": "pol", "pol": "pol", "tr": "tur", "tur": "tur",
    ]

    private static func inferSubLanguage(_ sub: URL) -> String? {
        let stem = sub.deletingPathExtension().lastPathComponent.lowercased()
        guard let dot = stem.lastIndex(of: ".") else { return nil }
        let suffix = String(stem[stem.index(after: dot)...])
        guard suffix.allSatisfy({ $0.isLetter }), (2...3).contains(suffix.count) else { return nil }
        if let mapped = langAliases[suffix] { return mapped }
        return suffix.count == 3 ? suffix : nil
    }
}
