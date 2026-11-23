# QCpie

**VERSION 0.19.7** · Video QC for macOS (Apple silicon)

Check deliverables, compare versions, scan for errors and send them to Frame.io in one app.

## Download

Get the latest DMG from [Releases](https://github.com/baguotti/QC/releases), open it and drag QCpie to Applications. QCpie checks for updates itself.

## Tabs

**Play** (⇧1)
- Frame-accurate player: J/K/L, frame stepping, smooth scrubbing, zoom to single pixels.
- A/B compare: side by side, split wipe, difference, overlay, blink (TAB).
- Exposure (−5 to +5 EV), legal-range zebra, subtitles (.srt), audio waveform.
- Timecoded notes with replies, synced between Macs; Frame.io comments come in as notes.

**Inspect** (⇧2)
- Resolution, frame rate, codec, timecode and audio for every file.
- Loudness (LUFS, true peak, LRA) against your delivery target.
- Subtitle spell check and cross-check between versions.

**Scan** (⇧3)
- Line Check: coloured edge lines and split-screen seams.
- Frame Check: frame-rate stutter, flash frames, Media Offline, illegal levels.
- Reports as HTML and CSV.

**Upload** (⇧4)
- Sign in with Adobe and upload the queue to Frame.io: fast, resumable, survives network drops.
- Browse projects, rename, move, stack versions, download, create share links.

## Formats

Video, audio, images and image sequences. MXF and other pro formats need Apple's free [Pro Video Formats](https://support.apple.com/101631). Files macOS can't open (WebM, MKV, AVI, WMV, VP9, AV1…) still show their specs in Inspect, read with FFmpeg's ffprobe; they can't be played or checked.

## Build from source

```bash
swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
./scripts/BuildApp.sh   # release app in build/
```

Architecture notes for contributors: [AGENTS.md](AGENTS.md).

## License

GPL-3.0: see [LICENSE](LICENSE). You may use, change and share QCpie; distributed changes must stay open source under the same license.

QCpie bundles **ffprobe** from [FFmpeg](https://ffmpeg.org) 9.0.2, built as LGPL v2.1 (`scripts/build_ffprobe.sh` downloads the [source](https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz) and lists the build flags). Its licence is in the app at `Contents/Resources/Helpers/FFMPEG_LICENSE.txt`. FFmpeg is a trademark of Fabrice Bellard.
