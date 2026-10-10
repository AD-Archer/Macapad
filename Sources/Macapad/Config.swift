import Foundation

/// Macapad's folder (~/.macapad) and the API token stored in it.
enum Config {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".macapad")
    static let tokenURL = directory.appendingPathComponent("token")

    /// Reads the token, creating a random one (readable only by you) on first launch.
    static func loadOrCreateToken() throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let existing = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return existing
        }
        let token = randomHex(bytes: 24)
        try token.write(to: tokenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        return token
    }

    /// Cryptographically random bytes as lowercase hex.
    static func randomHex(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess, "No randomness")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
