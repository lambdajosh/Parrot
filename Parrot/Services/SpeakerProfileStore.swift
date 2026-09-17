import Foundation
import SwiftData

/// Matching and upkeep for remembered voices. Stateless — every call takes
/// the ModelContext — so views and harnesses use it without wiring.
/// Nothing here writes a speaker name: `match` feeds the one-click "sounds
/// like" confirmation, and `autoAssignments` returns the names the caller
/// may apply without asking, marked as automatic so they stay reversible.
enum SpeakerProfileStore {
    /// Settings key: apply `autoAssignments` after diarization. Defaults on;
    /// only meaningful while "Remember voices" is on.
    static let autoNameKey = "autoNameVoices"

    /// Cosine floor for naming a voice without asking. Same measurements as
    /// `suggestThreshold`: a clean same-voice match sat at 0.96 and every
    /// different-voice pair at 0.50–0.53, so 0.85 keeps a 0.3 gap above every
    /// false match seen while still catching a clean call. Degraded audio
    /// (0.65–0.70) stays a suggestion the user clicks.
    static let autoNameThreshold: Float = 0.85

    /// Cosine similarity floor for "sounds like X" suggestions. Measured on
    /// real recordings: same voice on a clean call 0.96; same voice through
    /// degraded audio (played back over speakers and re-captured) 0.65–0.70;
    /// different voices 0.50–0.53. 0.7 missed two true matches at 0.66/0.68,
    /// so 0.65 — catches every true match seen while keeping a 0.11+ gap
    /// above every false one. Suggestion-only, so a rare false "sounds like?"
    /// costs one glance.
    // ponytail: single knob, used only by match(_:in:).
    static let suggestThreshold: Float = 0.65

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    static func profiles(in context: ModelContext) -> [SpeakerProfile] {
        (try? context.fetch(FetchDescriptor<SpeakerProfile>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    /// Best remembered voice at/above the threshold, or nil.
    static func match(_ embedding: [Float], in context: ModelContext) -> (name: String, similarity: Float)? {
        let best = profiles(in: context)
            .map { (name: $0.name, similarity: cosine(embedding, $0.embedding)) }
            .max { $0.similarity < $1.similarity }
        guard let best, best.similarity >= suggestThreshold else { return nil }
        return best
    }

    /// The voices to name without asking: each unnamed label's best remembered
    /// voice at or above `autoNameThreshold`, each name used once per meeting
    /// (highest similarity wins), and never a name already given to another
    /// voice in this meeting by hand. Pure, so the harness can drive it.
    static func autoAssignments(
        for embeddings: [String: [Float]],
        alreadyNamed: [String: String],
        profiles: [(name: String, embedding: [Float])]
    ) -> [String: String] {
        let takenNames = Set(alreadyNamed.values)
        var candidates: [(label: String, name: String, similarity: Float)] = []
        for (label, embedding) in embeddings where label != "Me" && alreadyNamed[label] == nil {
            for profile in profiles where !takenNames.contains(profile.name) {
                let similarity = cosine(embedding, profile.embedding)
                if similarity >= autoNameThreshold {
                    candidates.append((label, profile.name, similarity))
                }
            }
        }
        var result: [String: String] = [:]
        var usedNames = takenNames
        for candidate in candidates.sorted(by: { $0.similarity > $1.similarity })
        where result[candidate.label] == nil && !usedNames.contains(candidate.name) {
            result[candidate.label] = candidate.name
            usedNames.insert(candidate.name)
        }
        return result
    }

    static func autoAssignments(for embeddings: [String: [Float]], alreadyNamed: [String: String],
                                in context: ModelContext) -> [String: String] {
        autoAssignments(for: embeddings, alreadyNamed: alreadyNamed,
                        profiles: profiles(in: context).map { ($0.name, $0.embedding) })
    }

    /// Create or reinforce the profile named `name` with one more voice sample.
    static func remember(name: String, embedding: [Float], in context: ModelContext) {
        guard !embedding.isEmpty else { return }
        if let existing = profiles(in: context).first(where: { $0.name == name }) {
            let n = Float(existing.sampleCount)
            let old = existing.embedding
            guard old.count == embedding.count else { return }
            existing.embedding = old.indices.map { (old[$0] * n + embedding[$0]) / (n + 1) }
            existing.sampleCount += 1
            existing.updatedAt = .now
        } else {
            context.insert(SpeakerProfile(name: name, embedding: embedding))
        }
        try? context.save()
    }

    static func delete(_ profile: SpeakerProfile, in context: ModelContext) {
        context.delete(profile)
        try? context.save()
    }

    static func deleteAll(in context: ModelContext) {
        for profile in profiles(in: context) { context.delete(profile) }
        try? context.save()
    }
}
