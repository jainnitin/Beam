# Third-party licenses

## FFmpeg

Beam bundles the `ffmpeg` and `ffprobe` command-line tools to remux video and
embed subtitles. They are built from unmodified FFmpeg source and licensed under
the **GNU Lesser General Public License, version 2.1 or later (LGPL-2.1+)**.

- Version: 9.0
- Source: <https://ffmpeg.org/releases/>
- Build configuration: LGPL only — `--disable-gpl` (implicit), no GPL or
  non-free components, all encoders disabled except `movtext`. The exact
  configure line is in [`.github/workflows/release.yml`](.github/workflows/release.yml).
- License text: bundled at `Beam.app/Contents/Resources/ffmpeg-LICENSE.txt`.

Because Beam is open source and builds FFmpeg from a pinned, unmodified release
with a published configure line, the corresponding source and build scripts are
available here and at ffmpeg.org, satisfying the LGPL's source-availability terms.
