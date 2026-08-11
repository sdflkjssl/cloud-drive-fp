import Foundation

/// The credential the extension uses to reach the backend.
///
/// Host app writes it, extension reads it, both through the shared App Group
/// container.
///
/// 🔴 App Groups are a PROVISIONED capability. That is not a detail — it is why
/// a File Provider extension cannot be built with ad-hoc signing. The extension
/// and its host app must share a group to exchange anything at all, and a group
/// only exists inside the sandbox, so the extension is always sandboxed too.
///
/// 🔴 What is stored here sits in a plist inside the group container. That
/// container is sandbox-protected and reachable only by these two signed
/// bundles, but it is NOT the Keychain and should not be mistaken for one. Store
/// a scoped, individually revocable app password for one endpoint here — never an
/// account password. A keychain access group is the stronger option and a
/// drop-in replacement for this type.
enum Credentials {
    /// Must match the `com.apple.security.application-groups` entitlement on BOTH
    /// targets, and `NSExtensionFileProviderDocumentGroup` in the extension's
    /// Info.plist. If these drift, the extension silently enumerates nothing.
    static let appGroup = "group.com.quarkpan.plinth"

    private static let accountKey = "davAccount"
    private static let passwordKey = "davPassword"
    private static let baseURLKey = "davBaseURL"

    struct Pair: Sendable {
        let account: String
        let password: String
    }

    /// Lets the endpoint be repointed without rebuilding the extension.
    static var baseURL: URL? {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let raw = defaults.string(forKey: baseURLKey), !raw.isEmpty
        else { return nil }
        return URL(string: raw)
    }

    static var current: Pair? {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let account = defaults.string(forKey: accountKey), !account.isEmpty,
              let password = defaults.string(forKey: passwordKey), !password.isEmpty
        else { return nil }
        return Pair(account: account, password: password)
    }

    static func store(account: String, password: String, baseURL: String) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.set(account, forKey: accountKey)
        defaults.set(password, forKey: passwordKey)
        defaults.set(baseURL, forKey: baseURLKey)
    }

    static func clear() {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.removeObject(forKey: accountKey)
        defaults.removeObject(forKey: passwordKey)
    }
}
