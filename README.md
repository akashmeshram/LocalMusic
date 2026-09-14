# LocalMusic

A native macOS app (Swift 6, SwiftUI) that downloads audio from URLs you have permission to
download, identifies and tags it, files it into a clean folder structure under `~/Music/LocalMusic`,
and plays it back offline. No accounts, no analytics, no cloud.

**Status:** Phase 1 (working MVP) is complete: URL input, single-item and playlist downloads with
live progress, a queue with configurable concurrency, automatic filing into the library, a
library index that can be rebuilt from disk, playback with media-key support, and Finder
integration. Phases 2–4 (tag editing, artwork, MusicBrainz identification, albums/artists/playlists)
are described in `docs/SPEC.md` and `docs/superpowers/`.

## Requirements

| Requirement | Notes |
|---|---|
| macOS 14 Sonoma or later | Apple Silicon and Intel |
| `yt-dlp`, `ffmpeg`, `ffprobe` | installed through Homebrew (see below) |
| Xcode 16 **or** Command Line Tools with Swift 6 | to build from source |
| `fpcalc` (Chromaprint) | optional, for fingerprint matching in a later phase |

### Homebrew installation

```sh
brew install yt-dlp ffmpeg
```

Optional fingerprinting support (not yet used by Phase 1):

```sh
brew install chromaprint
```

The app looks for tools in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`, `~/.local/bin`,
and everything on your `PATH`. Paths can be overridden in **Settings → Advanced**. The app never
installs or upgrades anything itself; **Check for Tool Updates** only asks Homebrew what is outdated.

## Building

Three ways, one source tree:

```sh
# 1. Script build (no Xcode required; verified with Command Line Tools 16.4)
make            # → build/debug/LocalMusic.app
make run        # build and open
make test       # Swift Testing suite
make release    # optimized build

# 2. Swift Package Manager (needs a working SwiftPM)
swift build
swift test

# 3. Xcode project (needs XcodeGen: brew install xcodegen)
make xcodeproj  # generates LocalMusic.xcodeproj from project.yml
open LocalMusic.xcodeproj
```

The script build compiles `LocalMusicCore` as a static library, links the app against it, copies
`Info.plist`, and ad-hoc signs the bundle. `Scripts/sdk.sh` picks a macOS SDK the installed
compiler can actually use, which matters when the Command Line Tools carry a newer SDK than the
compiler (a real situation on the machine this was first built on).

Useful launch flags for development: `--mock` uses a simulated downloader that produces playable
WAV tones so the UI can be exercised offline; `--download=<url>` queues a URL at launch;
`--screenshot=<dir>` writes PNGs of the window a few seconds after launch.

## How the yt-dlp integration works

Every tool call goes through `ProcessRunner`, which uses `Process` + `Pipe` with an argument
array. There is no shell anywhere, and the URL is always the last argument after `--`, so nothing
pasted by the user can be interpreted as an option.

1. **Probe.** `yt-dlp --dump-single-json --flat-playlist` inspects the URL. A single item is
   queued directly. A playlist opens a preview sheet (title, count, entries) where items can be
   deselected. Each selected entry becomes its own job, so one failing item never aborts the rest.
2. **Download.** Per job, yt-dlp runs in a private folder `~/Music/LocalMusic/.incoming/<job-id>/`
   with `-f bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio/best`, `--embed-metadata`,
   `--embed-thumbnail`, `--write-info-json`, and `--download-archive` (so a source URL is never
   fetched twice). Progress arrives through `--progress-template` as `LMPROG|…` records that
   `YTDLPProgressParser` turns into percentage, bytes, speed, ETA and playlist position; the
   parser also understands yt-dlp's default human-readable progress line as a fallback. The final
   path comes from `--print after_move:filepath`.
3. **Format policy.** *Original* keeps the source stream (extracting audio without re-encoding).
   Only Opus/WebM sources are converted to M4A, because AVFoundation cannot play them. *M4A* and
   *MP3* force a compatibility conversion. If ffmpeg is missing or broken, yt-dlp still downloads
   the best audio stream, but no post-processing happens.
4. **Process, identify, organize, index.** The file is validated with AVFoundation, source metadata
   from `.info.json` is merged with embedded tags (never inventing values), `FileOrganizer` moves it
   to its final location, and `LibraryStore` records it. The job folder is deleted afterwards, so
   partial files never touch the library.
5. **Errors.** `YTDLPErrorClassifier` maps tool output to user-facing messages (private video,
   unavailable, region-restricted, sign-in required, network, disk full, permissions, cancelled).
   Raw output stays available under **Technical Details** on each queue row.

### TLS trust for yt-dlp

python.org builds of Python ship their own certificate store, so yt-dlp can fail with
`CERTIFICATE_VERIFY_FAILED` on networks with an inspecting proxy even though Safari and curl work.
LocalMusic exports the roots macOS trusts (`security find-certificate -p`) into
`~/Library/Application Support/LocalMusic/macos-trusted-roots.pem` and passes it to yt-dlp as
`SSL_CERT_FILE`. This grants yt-dlp exactly the trust the OS has; verification is never disabled.
Set `SSL_CERT_FILE` yourself to override.

## MusicBrainz API usage

Planned for Phase 3. The design: candidates are queried from the MusicBrainz recording search with
a descriptive `User-Agent` (`LocalMusic/<version> (<contact>)`), rate-limited to one request per
second, cached under `Application Support/LocalMusic/MetadataCache`, and ranked by artist, title,
duration, album and release-date similarity. Only high-confidence matches are applied
automatically; ambiguous ones are offered as a short list. Cover art comes from the Cover Art
Archive. Nothing in Phase 1 contacts MusicBrainz.

## Library folder structure

```
~/Music/LocalMusic/
├── .incoming/                       # private per-job folders; cleaned after every job
├── Daft Punk/
│   └── 2013 - Random Access Memories/
│       └── 01 - Give Life Back to Music.m4a
├── Some Artist/
│   └── Singles/
│       └── Track Without Album.m4a
└── Unknown Artist/
    └── Unknown Album/
        └── Unidentified Title.m4a
```

Templates are configurable in **Settings → Organization** (`{AlbumArtist} {Artist} {Album} {Year}
{Track} {Disc} {Title} {Genre}`). Every path component is sanitized (`/`, `:`, control characters,
leading dots, 200-byte limit on grapheme boundaries), collisions get a ` (2)` suffix after a
case-insensitive check, and no move or delete ever targets a path outside the library root.

The index lives in `~/Library/Application Support/LocalMusic/Library.sqlite`. Files are the source
of truth; **Library → Rebuild Library** drops the index and rescans the folder. Deleting from the
app moves files to the Trash.

## Troubleshooting

- **"Tools missing" / banner says ffmpeg is installed but fails to run.** A Homebrew upgrade can
  leave ffmpeg linked against a library version that is gone (for example
  `libx265.215.dylib`). Run `brew reinstall ffmpeg` (or `brew upgrade`), then click **Re-check**.
- **Downloads fail with a certificate error.** See *TLS trust for yt-dlp* above; also try
  `brew upgrade yt-dlp`.
- **YouTube says "Sign in to confirm you're not a bot".** yt-dlp is being rate-limited or blocked;
  wait, update yt-dlp, or try from another network. LocalMusic does not support cookies or logins.
- **A downloaded track will not play.** Only M4A/AAC, MP3, FLAC, WAV, AIFF and CAF play natively.
  Opus/WebM files are converted automatically when ffmpeg works; fix ffmpeg and re-download.
- **Build fails with "this SDK is not supported by the compiler".** The Command Line Tools have a
  newer SDK than the compiler. `Scripts/sdk.sh` works around it; alternatively reinstall the CLT or
  install Xcode.
- **`swift build` crashes on launch.** Some CLT installs ship a broken SwiftPM; use `make` instead.
- **Logs.** **Library → Open Logs Folder** opens `~/Library/Logs/LocalMusic/`. Logs never contain
  API keys.

## Privacy model

- Everything stays on this Mac: the index, artwork cache, logs, and the download archive.
- Network access happens only through yt-dlp to the site you pasted, and (in later phases) to
  MusicBrainz / Cover Art Archive for metadata you explicitly enable.
- No analytics, telemetry, accounts, or cloud sync. No third-party SDKs.
- Pasted URLs and downloaded metadata are treated as untrusted: they are never passed through a
  shell, and every derived file path is checked against the library root before use.
- The app is not sandboxed because it must execute unsigned Homebrew binaries that write into your
  Music folder; it deliberately touches only `~/Music/LocalMusic`, its own Application Support
  folder, and its log folder.
