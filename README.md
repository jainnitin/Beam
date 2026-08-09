# Beam

Beam is a small macOS app for playing local video and sending it to an Apple TV
over AirPlay. Drop in an `.mkv` or `.mp4` and play — Beam remuxes to an Apple
TV-friendly container on the fly without re-encoding, so there's no quality loss
and no long wait.

## Features

- Plays `.mp4`, `.mkv`, `.m4v`, `.mov`, `.avi`
- Fast stream-copy remux to MP4 (`hvc1` tagging for HEVC) — no transcoding
- Embeds SRT/ASS subtitles, or a subtitle file you choose, as selectable tracks
- AirPlay to Apple TV via the native player controls
- Transcodes Apple TV-incompatible audio (DTS, TrueHD…) to AC-3/AAC; video is never re-encoded
- Self-contained — a minimal LGPL build of ffmpeg is bundled, nothing to install
- Signed with a Developer ID and notarized by Apple
- Self-updates from GitHub Releases

## Requirements

- macOS 12 or later

## Install

Download `Beam.dmg` from the
[latest release](https://github.com/jainnitin/Beam/releases/latest), open it, and
drag **Beam** into **Applications**.

## Usage

1. Drop a video onto the window (or **Choose Video…**).
2. Pick a subtitle track if you want one.
3. **Play** — the video opens in the built-in player.
4. Hover over the video, click the AirPlay button, and choose your Apple TV.
5. Press **Esc** to return to the library.

## License

Beam is MIT — see [LICENSE](LICENSE). Bundled ffmpeg is LGPL-2.1+ — see
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).
