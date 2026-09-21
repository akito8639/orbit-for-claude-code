import Foundation

/// Access token shared with the widget extension through the App Group container, so the widget can
/// fetch usage on its own while the app is not running. Only the short-lived access token is shared
/// (refresh stays in the app, which writes back to Claude Code's own keychain item). The file is
/// readable only by this user account (0600) and lives next to snapshot.json.
///
/// A keychain access group would be the textbook answer, but on macOS that needs a provisioning
/// profile (`keychain-access-groups`) and the App Group fallback reports errSecMissingEntitlement
/// for non-sandboxed apps, so the container file is what works for Developer ID distribution.
enum SharedToken {
    static let fileName = "shared-token.json"

    struct Entry: Codable { var accessToken: String; var expiresAt: Date }

    private static var url: URL? { SnapshotStore.containerURL?.appendingPathComponent(fileName) }

    static func load() -> Entry? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Entry.self, from: data)
    }

    static func save(accessToken: String, expiresAt: Date) throws {
        guard let url else { throw NSError(domain: "Orbit", code: 3, userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable"]) }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(Entry(accessToken: accessToken, expiresAt: expiresAt)).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func delete() {
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}
