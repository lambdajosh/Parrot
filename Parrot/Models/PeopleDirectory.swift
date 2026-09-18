import Foundation

/// Display names for the identities the calendar hands over. Google events
/// often carry only an address ("alaski@lambdal.com"), and that address then
/// becomes the invitee chip, the speaker name, and the remembered voice's
/// name. An alias maps such an identity to how the user knows the person
/// ("Andrew Laski"), and every display path resolves through here, so one
/// alias fixes the transcript, the header, the export, and Settings at once.
///
/// Storage is a small JSON dictionary in UserDefaults, keyed by the identity
/// lower-cased and trimmed. Meetings keep the raw identity, never the alias,
/// so renaming later changes old transcripts too.
enum PeopleDirectory {
    static let key = "personAliases"

    static func canonical(_ identity: String) -> String {
        identity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Something that reads as an address rather than a name.
    static func looksLikeEmail(_ identity: String) -> Bool {
        let s = identity.trimmingCharacters(in: .whitespaces)
        guard let at = s.firstIndex(of: "@"), at > s.startIndex else { return false }
        return s[s.index(after: at)...].contains(".") && !s.contains(" ")
    }

    static func aliases(defaults: UserDefaults = .standard) -> [String: String] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }

    static func alias(for identity: String, defaults: UserDefaults = .standard) -> String? {
        aliases(defaults: defaults)[canonical(identity)]?.nilIfEmpty
    }

    /// The alias when one exists, otherwise the identity itself.
    static func displayName(for identity: String, defaults: UserDefaults = .standard) -> String {
        alias(for: identity, defaults: defaults) ?? identity
    }

    /// Sets, or with nil/empty clears, the alias for `identity`.
    static func setAlias(_ name: String?, for identity: String, defaults: UserDefaults = .standard) {
        var all = aliases(defaults: defaults)
        let k = canonical(identity)
        guard !k.isEmpty else { return }
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            all[k] = name
        } else {
            all.removeValue(forKey: k)
        }
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: .parrotPeopleChanged, object: nil)
    }
}

// MARK: - The People list

extension PeopleDirectory {
    /// One person as the Settings list shows them: a display name, every
    /// identity that resolves to it (a voice's name, an address or two), and
    /// the remembered voice if any. Identities merge by display name, so an
    /// address aliased "Allison Beck" and a voice named "Allison Beck" are
    /// one person.
    struct Person: Equatable {
        var name: String
        var identities: [String]
        var voiceName: String?
        var voiceSamples: Int
        /// Something was typed for this person: an alias, or a voice with a
        /// real name (not an address).
        var isNamed: Bool

        var addresses: [String] { identities.filter { PeopleDirectory.looksLikeEmail($0) } }
        var hasVoice: Bool { voiceName != nil }
    }

    /// Builds the list. Voices first, then named people without a voice, then
    /// bare addresses from invites; each group alphabetical.
    static func people(voices: [(name: String, samples: Int)], aliases: [String: String],
                       inviteIdentities: [String]) -> [Person] {
        var byName: [String: Person] = [:]
        var order: [String] = []
        func key(_ identity: String) -> String {
            canonical(aliases[canonical(identity)]?.nilIfEmpty ?? identity)
        }
        func upsert(_ identity: String, voice: (name: String, samples: Int)? = nil) {
            let k = key(identity)
            guard !k.isEmpty else { return }
            if var existing = byName[k] {
                if !existing.identities.contains(where: { canonical($0) == canonical(identity) }) {
                    existing.identities.append(identity)
                }
                if let voice, existing.voiceName == nil {
                    existing.voiceName = voice.name
                    existing.voiceSamples = voice.samples
                }
                if aliases[canonical(identity)] != nil { existing.isNamed = true }
                byName[k] = existing
            } else {
                order.append(k)
                let alias = aliases[canonical(identity)]?.nilIfEmpty
                byName[k] = Person(
                    name: alias ?? identity,
                    identities: [identity],
                    voiceName: voice?.name,
                    voiceSamples: voice?.samples ?? 0,
                    isNamed: alias != nil || (voice != nil && !looksLikeEmail(identity)))
            }
        }
        for voice in voices { upsert(voice.name, voice: voice) }
        for (identity, _) in aliases { upsert(identity) }
        for identity in inviteIdentities { upsert(identity) }
        func rank(_ p: Person) -> Int { p.hasVoice ? 0 : (p.isNamed ? 1 : 2) }
        return order.compactMap { byName[$0] }.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

extension Notification.Name {
    /// An alias was added, changed, or removed; views showing names redraw.
    static let parrotPeopleChanged = Notification.Name("parrotPeopleChanged")
}
