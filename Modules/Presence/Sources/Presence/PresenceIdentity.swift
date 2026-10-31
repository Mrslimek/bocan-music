import Foundation

/// The persistent peer identity advertised in the mDNS TXT `id` field and used
/// as the envelope `from`. The id is a lowercased UUID v4 persisted in
/// `UserDefaults` so it survives relaunches; the tie-break rule (section 3)
/// compares ids byte-wise, so a stable id is load-bearing.
public struct PresenceIdentity: Sendable {
    public let id: String
    /// Resolved per use via the injected closure so the module never imports
    /// AppKit for `Host.current().localizedName` (same pattern as SyncServer).
    public let name: @Sendable () -> String

    public init(id: String, name: @escaping @Sendable () -> String) {
        self.id = id
        self.name = name
    }

    /// Loads the persisted device id, minting and storing one on first use.
    public static func persisted(defaults: UserDefaults = .standard, key: String = "presence.deviceId") -> Self {
        let id: String
        if let stored = defaults.string(forKey: key), !stored.isEmpty {
            id = stored
        } else {
            let minted = UUID().uuidString.lowercased()
            defaults.set(minted, forKey: key)
            id = minted
        }
        return Self(id: id) {
            Host.current().localizedName ?? "Bòcan"
        }
    }
}
