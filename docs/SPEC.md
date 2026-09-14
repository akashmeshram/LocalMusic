# LocalMusic — Product Specification (as supplied)

Build a polished native macOS app called **LocalMusic** for downloading, identifying, organizing, and playing locally stored music from supported URLs for media the user has permission to download. Swift + SwiftUI, current macOS versions.

## Core workflow
`URL → yt-dlp → temporary download → metadata identification → artwork → organized Music folder → local library`

Library root: `~/Music/LocalMusic/`. Layout: `{Album Artist}/{Year} - {Album}/{Track Number} - {Title}.{ext}`; singles: `Artist/Singles/Title.ext`; unidentified: `Unknown Artist/Unknown Album/Title.ext`. Unfinished downloads live in `~/Music/LocalMusic/.incoming/`; partial files never enter the final library.

## Download engine
Installed CLI tools `yt-dlp`, `ffmpeg`, `ffprobe` executed via `Process`/`Pipe` (no shell). Accept video and playlist URLs; best audio; prefer original M4A/AAC; avoid unnecessary transcoding; optional compatibility conversion to M4A/MP3; embed metadata and thumbnails; parse progress (percentage, downloaded, total, speed, ETA, playlist item); cancel; queue; configurable concurrency (default 1); download archive to avoid re-downloads.

## Dependency management
Detect tools at launch across Homebrew paths (Apple Silicon + Intel). Show versions; if missing, instruct `brew install yt-dlp ffmpeg`. "Check for tool updates" action. Never silently install.

## Automatic metadata identification
Pipeline: read yt-dlp metadata → clean title noise (Official Video/Audio, Lyrics, HD, 4K, Visualizer, Remastered, "- Topic") → extract artist/title/album/year → query MusicBrainz → rank (artist, title, duration, album, date) → auto-accept high confidence only → show 3–5 candidates when ambiguous → preserve original metadata when nothing reliable. Respect MB rate limits, proper User-Agent, cache lookups locally.

## Optional fingerprinting
Design for AcoustID/Chromaprint (`fpcalc`), used only when text matching is insufficient; app works without credentials.

## Metadata editing
Editable: title, artist, album artist, album, track #, disc #, genre, year, composer. Written into the audio file, preserving quality.

## Album artwork
Priority: Cover Art Archive → embedded source artwork → video thumbnail. Cache locally; replace/remove/drag-and-drop.

## File organization
Sanitize `/`, `:`, Unicode, emoji, long names, duplicates, case-insensitive collisions. Never overwrite without explicit duplicate handling.

## Duplicate detection
Signals: source URL, MB recording ID, artist + normalized title, duration, optional fingerprint. Offer Skip / Keep both / Replace / Show existing. Never delete automatically.

## Local library database
SwiftData or Core Data index with: track ID, file URL, source URL, extractor, title, artist, album artist, album, track #, disc #, genre, year, duration, format, size, artwork ref, MB recording/release IDs, date added, download date, play count, favorite. Files are the source of truth; "Rebuild Library" rescans.

## Library interface
Three-column layout. Sidebar: Songs, Albums, Artists, Recently Added, Favorites, Downloads, Playlists. Search/sort/filter, album grid, song table (Artwork, Title, Artist, Album, Year, Duration, Format, Date Added). Context menu: Play, Play Next, Add to Queue, Add to Playlist, Edit Metadata, Reveal in Finder, Copy Source URL, Re-identify Metadata, Delete.

## Playback
AVFoundation: play/pause, prev/next, seek, volume, queue, shuffle, repeat, media keys. Compact now-playing bar. Fully offline.

## Playlists
Local playlists in the DB: create/rename/delete, drag tracks in, reorder; `.m3u8` import/export.

## Download UI
Prominent URL input with Download and Paste & Download. Playlist preview (title, count, track list, deselect). Queue rows: artwork, title, status, progress, speed, ETA. States: Waiting, Downloading, Processing, Identifying, Organizing, Complete, Failed, Cancelled.

## Settings
Downloads (directory, format, concurrency, auto-start), Metadata (auto MB, min confidence, prefer earliest release, replace thumbnails, AcoustID key), Organization (folder/filename templates, auto-organize), Playback (remember position, default volume), Advanced (tool paths, rebuild library, clear metadata cache, open logs).

## Logging and errors
Structured local logs, no secrets. Human-readable errors with expandable Technical Details. Handle unavailable/private/deleted/region-restricted videos, malformed URLs, network errors, MusicBrainz downtime, invalid audio, permissions, low disk space, cancellation. One failed playlist item never aborts the playlist.

## macOS integration
Finder reveal, drag and drop, shortcuts, menu commands, system media controls, notifications for large queues, sandbox-compatible access where possible, minimal permissions.

## Architecture
Modular: App/, Models/, Views/, ViewModels/, Services/ (Download, YTDLP, FFmpeg, Metadata, MusicBrainz, Artwork, Library, Playback, FileOrganizer, DuplicateDetector), Persistence/, Utilities/. Swift concurrency; never block the main thread; light DI.

## Security
Untrusted URLs/metadata; arguments passed directly to Process; validate paths; filenames never escape the library root; no analytics/accounts/cloud; API keys in Keychain.

## Testing
Unit tests: filename sanitization, title cleanup, MB scoring, duplicate detection, folder generation, progress parsing. Mock services for UI work.

## Phases
1. MVP: app, URL input, yt-dlp, progress, queue, save to library root, scanner, playback, Finder.
2. Organization: metadata extraction, folder organization, tag editing, artwork embedding, duplicates.
3. Smart metadata: MusicBrainz, scoring, thresholds, manual match UI, Cover Art Archive.
4. Full library: albums, artists, playlists, search, favorites, queue, advanced settings.
