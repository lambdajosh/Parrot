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

extension Notification.Name {
    /// An alias was added, changed, or removed; views showing names redraw.
    static let parrotPeopleChanged = Notification.Name("parrotPeopleChanged")
}
