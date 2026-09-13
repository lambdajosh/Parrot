import Foundation

/// Exports meeting transcripts to TXT and SRT formats.
enum ExportService {

    // MARK: - Plain Text Export

    static func exportToTXT(meeting: Meeting) -> String {
        var output = """
        Meeting: \(meeting.title)
        Date: \(formatDate(meeting.date))
        Duration: \(meeting.formattedDuration)
        Speakers: \(meeting.speakerCount)

        """

        if !meeting.notes.isEmpty {
            output += """

            === My Notes ===

            \(meeting.notes)

            """
        }

        if let summary = meeting.summary {
            output += """

            === Summary ===

            \(summary)

            """
        }

        if let coaching = meeting.coaching {
            output += """

            === Coaching & Follow-ups ===

            \(coaching)

            """
        }

        if !meeting.insights.isEmpty {
            output += "\n=== Copilot Insights ===\n\n"
            for insight in meeting.sortedInsights {
                let style = KindResolver.style(forKey: insight.kindRaw, profile: meeting.profile, snapshot: meeting.snapshotKinds)
                var line = "[\(insight.formattedCallTime)] \(style.label): \(insight.title)"
                if style.isPinned {
                    line += insight.isHandled ? " (handled)" : " (UNRESOLVED)"
                }
                output += line + "\n"
                output += "    \(insight.detail)\n"
                if let source = insight.source {
                    output += "    Source: \(source)\n"
                }
            }
        }

        output += "\n=== Transcript ===\n\n"
        for segment in meeting.sortedSegments {
            let speaker = meeting.displayName(forSpeaker: segment.speakerLabel)
            output += "[\(segment.formattedTimestamp)] \(speaker): \(segment.text)\n"
        }

        return output
    }

    // MARK: - SRT Export

    static func exportToSRT(meeting: Meeting) -> String {
        var output = ""
        let segments = meeting.sortedSegments

        for (index, segment) in segments.enumerated() {
            let speaker = segment.speakerLabel != nil ? "[\(meeting.displayName(forSpeaker: segment.speakerLabel))] " : ""
            output += """
            \(index + 1)
            \(srtTimestamp(segment.startTime)) --> \(srtTimestamp(segment.endTime))
            \(speaker)\(segment.text)


            """
        }

        return output
    }

    // MARK: - Save to File

    /// Filename stem for a meeting's exports: the title with spaces as
    /// underscores. Path-unsafe characters are handled in `save`.
    static func filename(for meeting: Meeting) -> String {
        meeting.title.replacingOccurrences(of: " ", with: "_")
    }

    /// Writes the transcript TXT for a meeting into the configured export
    /// folder (Settings → General → Storage) and returns where it landed.
    static func saveTXT(meeting: Meeting) throws -> URL {
        try save(content: exportToTXT(meeting: meeting), filename: filename(for: meeting), extension: "txt")
    }

    static func save(content: String, filename: String, extension ext: String,
                     directory: URL = TranscriptExportLocation.directory()) throws -> URL {
        // A user-chosen folder outside Downloads is only reachable through its
        // security-scoped bookmark; Downloads (and any unscoped URL) just
        // returns false here and needs no matching stop.
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        // Filenames come from user-typed meeting titles — "/" and ":" break the
        // path, and identical titles must not silently overwrite prior exports.
        let safe = filename
            .components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-")
        var url = directory.appendingPathComponent("\(safe).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(safe) (\(n)).\(ext)")
            n += 1
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Helpers

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func srtTimestamp(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}

// MARK: - Export location

/// Where transcript exports land (Settings → General → Storage). Downloads by
/// default, since the sandbox grants it outright. Any other folder the user picks is
/// kept as a security-scoped bookmark, the only form of access to a
/// user-selected folder that survives a relaunch of a sandboxed app.
enum TranscriptExportLocation {
    static let bookmarkKey = "transcriptExportBookmark"
    /// Toggle: write a TXT on its own once each call's post-processing finishes.
    static let autoSaveKey = "autoSaveTranscripts"

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }

    static func isCustom(defaults: UserDefaults = .standard) -> Bool {
        defaults.data(forKey: bookmarkKey) != nil
    }

    /// The configured folder, or Downloads when none is set or the bookmark no
    /// longer resolves (folder deleted, volume gone). A stale-but-resolvable
    /// bookmark is re-minted in place so it keeps working.
    static func directory(defaults: UserDefaults = .standard) -> URL {
        guard let data = defaults.data(forKey: bookmarkKey) else { return downloads }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return downloads
        }
        if stale {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                 includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(fresh, forKey: bookmarkKey)
            }
        }
        return url
    }

    /// Remembers a folder the user just picked; nil goes back to Downloads.
    /// The URL must still be within its open-panel grant when called.
    static func set(_ url: URL?, defaults: UserDefaults = .standard) throws {
        guard let url else {
            defaults.removeObject(forKey: bookmarkKey)
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: .withSecurityScope,
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: bookmarkKey)
    }
}
