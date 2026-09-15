import SwiftUI
import LocalMusicCore

/// Lets the user choose among MusicBrainz candidates for a track (or keep the current metadata).
struct MatchPickerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let track: TrackRecord
    let initialCandidates: [ScoredCandidate]
    var onApplied: (() -> Void)? = nil

    @State private var candidates: [ScoredCandidate] = []
    @State private var selected: ScoredCandidate.ID?
    @State private var isLoading = false
    @State private var isApplying = false
    @State private var errorMessage: String?
    @State private var usedFingerprint = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Identify “\(track.title)”").font(.title3.weight(.semibold))
                Text("Current: \(track.displayArtist) — \(track.displayAlbum) · \(DurationFormatter.string(track.duration))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            Divider()
            Group {
                if isLoading {
                    VStack(spacing: 8) { ProgressView(); Text("Asking MusicBrainz…").font(.caption).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if candidates.isEmpty {
                    ContentUnavailableView("No plausible matches", systemImage: "questionmark.circle",
                                           description: Text(errorMessage ?? "MusicBrainz has nothing close enough. The original metadata is kept; you can still edit it by hand."))
                } else {
                    List(candidates, selection: $selected) { c in
                        HStack(alignment: .top, spacing: 12) {
                            Text(String(format: "%.0f%%", c.score * 100))
                                .font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
                                .foregroundStyle(c.score >= env.settings.minimumAutoMatchConfidence ? .green : (c.score >= 0.6 ? .orange : .secondary))
                                .frame(width: 48, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(c.recording.artistCredit) — \(c.recording.title)").font(.body.weight(.medium))
                                if let r = c.release {
                                    HStack(spacing: 6) {
                                        Text(r.title)
                                        if let y = r.year { Text("(\(String(y)))") }
                                        if let t = r.primaryType { Text("· \(t)") }
                                        if r.isCompilation { Text("· compilation") }
                                        if let n = r.trackNumber { Text("· track \(n)\(r.trackCount.map { "/\($0)" } ?? "")") }
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("No release information").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack(spacing: 10) {
                                    if let d = c.recording.duration { Text(DurationFormatter.string(d)).monospacedDigit() }
                                    ForEach(["title", "artist", "duration"], id: \.self) { k in
                                        if let v = c.breakdown[k] { Text("\(k) \(Int(v * 100))%") }
                                    }
                                    if let f = c.breakdown["fingerprint"] { Text("fingerprint \(Int(f * 100))%") }
                                }
                                .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(c.id)
                    }
                }
            }
            Divider()
            HStack {
                if usedFingerprint { Label("Fingerprint used", systemImage: "waveform.badge.magnifyingglass").font(.caption).foregroundStyle(.secondary) }
                Button("Search Again") { Task { await search() } }.disabled(isLoading || isApplying)
                Spacer()
                if let errorMessage, !candidates.isEmpty { Text(errorMessage).font(.caption).foregroundStyle(.red) }
                Button("Keep Current") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isApplying ? "Applying…" : "Use Selected Match") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || isApplying || isLoading)
            }
            .padding()
        }
        .frame(width: 640, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            candidates = initialCandidates
            selected = candidates.first?.id
            if candidates.isEmpty { Task { await search() } }
        }
    }

    private func search() async {
        isLoading = true
        errorMessage = nil
        let outcome = await env.library.reidentify(track)
        candidates = outcome.candidates
        usedFingerprint = outcome.usedFingerprint
        selected = candidates.first?.id
        errorMessage = outcome.error?.message
        isLoading = false
    }

    private func apply() {
        guard let candidate = candidates.first(where: { $0.id == selected }) else { return }
        isApplying = true
        Task {
            do {
                try await env.library.apply(candidate: candidate, to: track)
                onApplied?()
                dismiss()
            } catch {
                errorMessage = LocalMusicError.wrap(error).message
            }
            isApplying = false
        }
    }
}
