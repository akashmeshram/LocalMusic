# LocalMusic — Design Record

The functional specification for LocalMusic was supplied in full by the project owner
(see `docs/SPEC.md`). This document records only the engineering decisions that the
specification leaves open, and the constraints of the machine it was first built on.

## Environment constraints (2026-09-14)

| Item | State on this machine | Consequence |
|---|---|---|
| Xcode.app | not installed | `xcodebuild` unavailable; `.xcodeproj` cannot be verified here |
| Command Line Tools | 16.4 (Swift 6.1.2) with a stray macOS 26.2 SDK | must pass `-sdk …/MacOSX15.5.sdk` explicitly |
| SwiftPM (`swift build`) | crashes (llbuild symbol mismatch) | build via a direct `swiftc` script; keep `Package.swift` for healthy toolchains |
| SwiftData macros | absent from CLT (Xcode-only plugin) | use **Core Data with a programmatic model** |
| XCTest | absent from CLT | use **Swift Testing** (`Testing.framework` is present) |
| `ffmpeg` (Homebrew 8.1) | fails to launch: missing `libx265.215.dylib` | fix with `brew reinstall ffmpeg`; app must surface "found but not runnable" |
| `yt-dlp` | `/usr/local/bin/yt-dlp` 2026.03.17 | Intel-prefix path must be in the search list |

## Decisions

### D1 — Build system
Three entry points, one source tree:
1. `Package.swift` — canonical description (targets `LocalMusicCore`, `LocalMusic`, `LocalMusicTests`). Works with `swift build` / Xcode "open package" when the toolchain is healthy.
2. `project.yml` — XcodeGen description producing a real `LocalMusic.xcodeproj` with Info.plist, entitlements and test target.
3. `Makefile` + `Scripts/build.sh` — direct `swiftc` build that auto-selects a compatible SDK, produces `build/LocalMusic.app`, ad-hoc signs it. `Scripts/test.sh` compiles the tests against `Testing.framework` and runs them. This is the path verified on this machine.

### D2 — Two modules
`LocalMusicCore` (Models, Services, Persistence, Utilities; no SwiftUI) and the `LocalMusic` app (App, Views, ViewModels). The core has a `public` API and is what the tests import. Rationale: identical layout under SwiftPM and the script build; mocks live in the core so previews never touch the network.

### D3 — Persistence
Core Data, `NSManagedObjectModel` built in code (no `.xcdatamodeld`, so no `momc`). Views never see `NSManagedObject`; `LibraryStore` exposes `Sendable` value types (`TrackRecord`). The store is an index only; `Rebuild Library` drops it and rescans `~/Music/LocalMusic`.

### D4 — Concurrency model
Swift 6 language mode. `ProcessRunner` is an actor streaming stdout/stderr lines as an `AsyncStream`. `YTDLPService` is an actor over it. `DownloadManager` is `@MainActor @Observable` and owns the queue, one `Task` per active job, bounded by `maxConcurrentDownloads`. `PlaybackService` is `@MainActor` over `AVPlayer`.

### D5 — yt-dlp contract
Arguments only, never a shell. Progress via `--newline --progress-template` emitting `LMPROG|…` records; final path via `--print after_move:LMFILE|%(filepath)s`; metadata via `--write-info-json` in the job's private incoming directory `~/Music/LocalMusic/.incoming/<jobID>/`. Playlists are expanded first with `--flat-playlist -J`; each entry becomes its own job so one failure never aborts the rest.

### D6 — Format policy
`-f bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio`. Original stream is kept when it is natively playable by AVFoundation (m4a/aac, mp3, flac, wav, aiff). Opus/WebM sources are converted to M4A because AVFoundation cannot play them; that is the only automatic transcode. Optional compatibility setting forces M4A or MP3.

### D7 — Sandbox
Not sandboxed. The app must exec unsigned Homebrew binaries and let them write to `~/Music/LocalMusic`; a sandboxed parent cannot hand that to an uninherited child. File access is still confined in code: every destination path is validated to sit under the music root before any move or delete. No entitlements beyond none; ad-hoc signed.

### D8 — Playback
`AVPlayer` with a periodic time observer; `MPRemoteCommandCenter`/`MPNowPlayingInfoCenter` for media keys and the system Now Playing widget.

### D9 — Logging
`os.Logger` plus a rotating file log in `~/Library/Logs/LocalMusic/`. Tool stderr is stored per job for the "Technical Details" disclosure. Nothing that could be a credential is ever logged.
