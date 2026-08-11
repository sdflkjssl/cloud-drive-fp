import AppKit
import FileProvider
import Foundation

/// Registers the drive with the system.
///
/// 🔴 A File Provider extension does nothing on its own. The host app has to
/// declare a domain for it, and only then does the drive appear under Locations
/// in Finder. Installing the app is not enough; nothing happens until this runs.
///
/// Registration is idempotent and survives restarts, so it is safe on every
/// launch.
enum DriveDomain {
    static let identifier = NSFileProviderDomainIdentifier("plinth-drive")
    static let displayName = "Plinth"

    /// 🔴 BUMP THIS WHENEVER ITEM IDENTIFIERS OR CAPABILITIES CHANGE SHAPE.
    ///
    /// The system keeps its own store of every item this provider ever vended —
    /// identifiers, capabilities, versions — and it does NOT rebuild that store
    /// just because the extension binary changed. Rebuilding the app is not
    /// enough, and neither is restarting the daemon.
    ///
    /// That is not a theory. Going from path identifiers to stable ids, the new
    /// extension was installed and correctly bound, and the drive still refused
    /// every write: the container was still marked read-only from the CACHED
    /// capabilities, so the system rejected each attempt locally and never called
    /// the provider at all. No error, no server traffic, nothing in any log —
    /// just a drive that quietly would not take a file.
    ///
    ///   1 — identifiers were paths; read-only.
    ///   2 — identifiers are the backend's stable ids; writable.
    static let schemaVersion = 7
    private static let schemaKey = "driveSchemaVersion"

    /// 🔴 CALLED FROM APP SCOPE, NEVER FROM A VIEW.
    ///
    /// A `.task` on a WindowGroup does not run when the launch window is
    /// suppressed — for a menu-bar app, or any app launched headless, that is
    /// every launch. Registration, the migration below and the working-set signal
    /// would all simply not happen, silently.
    ///
    /// A view task is also the wrong owner for the migration specifically:
    /// cancellation between the `remove` and the `add` — there is a two-second
    /// sleep in between — would leave the domain removed and the version key
    /// unbumped, i.e. the drive gone from Finder until some later launch happened
    /// to complete the round trip.
    @MainActor private static var didRegister = false

    @MainActor
    static func register() async {
        guard !didRegister else { return }
        didRegister = true
        let domain = NSFileProviderDomain(identifier: identifier, displayName: displayName)
        let defaults = UserDefaults(suiteName: Credentials.appGroup)
        let known = defaults?.integer(forKey: schemaKey) ?? 0

        do {
            let existing = try await NSFileProviderManager.domains()
            let present = existing.contains { $0.identifier == identifier }

            if present && known != schemaVersion {
                // The header sanctions exactly this: "in case the extension has
                // lost its synchronisation state and is not interested in
                // preserving the data cached on disk, it can remove and re-add
                // the affected domain."
                //
                // 🔑 Chosen over `reimportItemsBelowItemWithIdentifier`
                // deliberately. Reimport calls createItem for every item it finds
                // cached on disk — which, for a writable provider, would try to
                // upload the whole local cache back to the server. Nothing cached
                // here is precious: the drive is a mirror and every file is one
                // download away. If your cache CAN hold the only copy of
                // something, reimport is the correct call and this is not.
                NSLog("[plinth] schema \(known) → \(schemaVersion); rebuilding the domain")
                try? await NSFileProviderManager.remove(domain)
                // 🔴 The removal has to actually land before the add, or the
                // system resurrects the old backing store instead of building a
                // new one.
                try? await Task.sleep(for: .seconds(2))
                try await NSFileProviderManager.add(domain)
                defaults?.set(schemaVersion, forKey: schemaKey)
                NSLog("[plinth] domain rebuilt at schema \(schemaVersion)")
                return
            }

            if present {
                if let manager = NSFileProviderManager(for: domain) {
                    try? await manager.signalEnumerator(for: .workingSet)
                }
                // 🔑 Logged so that "did registration run this launch?" is an
                // observable fact rather than an inference. This path used to
                // return in silence, which made the common case — domain already
                // present, schema current — indistinguishable from register()
                // never having been called at all. That mattered precisely when it
                // was true.
                NSLog("[plinth] domain present at schema \(schemaVersion); working set signalled")
                return
            }

            try await NSFileProviderManager.add(domain)
            defaults?.set(schemaVersion, forKey: schemaKey)
            NSLog("[plinth] registered domain \(identifier.rawValue)")
        } catch {
            NSLog("[plinth] could not register domain: \(error.localizedDescription)")
        }
    }

    static func unregister() async {
        let domain = NSFileProviderDomain(identifier: identifier, displayName: displayName)
        try? await NSFileProviderManager.remove(domain)
    }

    static func isRegistered() async -> Bool {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        return domains.contains { $0.identifier == identifier }
    }

    /// 🔴 `FileManager.fileExists` on `~/Library/CloudStorage/…` ALWAYS returns
    /// false from inside the sandbox — that path is outside the container, so any
    /// UI gated on it is permanently disabled. Ask the manager instead.
    ///
    /// 🔴 The URL it returns is SECURITY-SCOPED. Without
    /// `startAccessingSecurityScopedResource()` the failure reads as
    /// "<app> does not have permission to open <drive>", which looks like a TCC
    /// problem and sends you to Full Disk Access. It is an unclaimed grant, not a
    /// missing one.
    static func revealInFinder() async {
        let domain = NSFileProviderDomain(identifier: identifier, displayName: displayName)
        guard let manager = NSFileProviderManager(for: domain),
              let url = try? await manager.getUserVisibleURL(for: .rootContainer)
        else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.open(url)
    }
}
