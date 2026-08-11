import FileProvider
import CryptoKit

/// Lists one container's children.
///
/// The system creates one of these per folder the user opens, and calls it again
/// on refresh. Enumeration here is a single PROPFIND Depth 1 — the backend
/// returns exactly one level, so there is no paging to do and the whole page is
/// delivered in one shot. A backend with large directories would page here.
final class DriveEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: DavClient.Ref

    init(container: DavClient.Ref) {
        self.container = container
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        // 🔑 Capture by value rather than closing over self: the enumerator is a
        // plain class and Swift 6 will not let a Task capture it, so reaching
        // through self is what trips region isolation — not the observer.
        nonisolated(unsafe) let observer = observer
        let container = container
        Task {
            do {
                let entries = try await DavClient.shared.list(container)
                observer.didEnumerate(entries.map { DriveItem(entry: $0) })
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(Self.translate(error))
            }
        }
    }

    /// Called when the system wants to know what changed since `anchor`.
    ///
    /// 🔴 THIS CANNOT REPORT CHANGES HONESTLY, SO IT DOES NOT PRETEND TO.
    ///
    /// A plain WebDAV backend has no change feed — there is no server-side
    /// journal saying "these three things moved". An earlier version papered over
    /// that by re-reporting every item as updated and never reporting a deletion,
    /// which meant a file deleted on the server stayed visible in Finder forever.
    /// Reporting only additions is not a sync; it is a leak of stale state.
    ///
    /// So the anchor is a fingerprint of the container's actual contents. If it
    /// still matches, nothing changed and this is cheap. If it does not, the only
    /// truthful answer is `syncAnchorExpired`, which the header defines as "the
    /// value of the sync anchor is too old, and the system must re-sync from
    /// scratch" — the system then re-enumerates and works out the deletions
    /// itself, which it can do and this extension cannot.
    ///
    /// A backend WITH a change feed should report real changes here instead. This
    /// is the honest fallback, not the goal.
    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        nonisolated(unsafe) let observer = observer
        let container = container
        Task {
            do {
                let entries = try await DavClient.shared.list(container)
                let current = Self.anchor(for: entries)
                if current == anchor {
                    observer.finishEnumeratingChanges(upTo: current, moreComing: false)
                } else {
                    observer.finishEnumeratingWithError(
                        NSFileProviderError(.syncAnchorExpired))
                }
            } catch {
                observer.finishEnumeratingWithError(Self.translate(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        nonisolated(unsafe) let completionHandler = completionHandler
        let container = container
        Task {
            let entries = try? await DavClient.shared.list(container)
            completionHandler(Self.anchor(for: entries ?? []))
        }
    }

    /// A fingerprint of exactly what is in the container right now: every id
    /// paired with its content version and name, order-independent. Any add,
    /// remove, rename or edit changes it; nothing else does.
    private static func anchor(for entries: [DavEntry]) -> NSFileProviderSyncAnchor {
        let material = entries
            .map { "\($0.id):\($0.etag):\($0.name)" }
            .sorted()
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(material.utf8))
        return NSFileProviderSyncAnchor(Data(digest))
    }

    /// Surface a missing credential as "not authenticated" so Finder offers to
    /// sign in rather than showing a generic failure the user cannot act on.
    private static func translate(_ error: Error) -> Error {
        if case DavError.noCredentials = error {
            return NSFileProviderError(.notAuthenticated)
        }
        if case DavError.http(let code) = error, code == 401 || code == 403 {
            return NSFileProviderError(.notAuthenticated)
        }
        return error
    }
}

/// Answers the system's synthetic containers with nothing, immediately.
///
/// 🔴 Returning an error here would be wrong — these containers legitimately
/// exist, they just have no contents on this provider — and running a real
/// enumeration would send their identifiers to the backend as if they were
/// paths. That is the `PROPFIND /dav/NSFileProviderWorkingSetContainerItemIdentifier`
/// 404 loop this replaced.
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("empty".utf8)))
    }
}
