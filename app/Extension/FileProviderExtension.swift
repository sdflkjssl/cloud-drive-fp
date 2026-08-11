import FileProvider
import UniformTypeIdentifiers

/// The drive.
///
/// This is what makes a remote server appear under Locations in Finder with its
/// own name and icon, rather than as a mounted network share with a generic
/// volume icon. That presentation is the entire reason a File Provider extension
/// exists — a WebDAV mount can work perfectly and still not look like a drive.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    // MARK: - Materialized (downloaded) item tracking
    // Decorations (checkmark) need to know which items are downloaded locally.
    private static let downloadedKey = "downloadedIDs"
    private static let downloadedLock = NSLock()
    nonisolated(unsafe) private static var downloadedIDs: Set<String> = {
        let defaults = UserDefaults(suiteName: Credentials.appGroup)
        return Set(defaults?.stringArray(forKey: downloadedKey) ?? [])
    }()
    static func isDownloaded(_ id: String) -> Bool {
        downloadedLock.lock()
        defer { downloadedLock.unlock() }
        return downloadedIDs.contains(id)
    }
    static func markDownloaded(_ id: String) {
        downloadedLock.lock()
        let inserted = downloadedIDs.insert(id).inserted
        downloadedLock.unlock()
        guard inserted else { return }
        UserDefaults(suiteName: Credentials.appGroup)?.set(Array(downloadedIDs), forKey: downloadedKey)
    }

    private let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {}

    // MARK: - Items

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        if identifier == .rootContainer {
            completionHandler(DriveItem(root: true), nil)
            progress.completedUnitCount = 1
            return progress
        }
        nonisolated(unsafe) let done = completionHandler
        Task {
            do {
                guard let entry = try await DavClient.shared.stat(.id(identifier.rawValue)) else {
                    done(nil, Self.missing(identifier))
                    progress.completedUnitCount = 1
                    return
                }
                done(DriveItem(entry: entry), nil)
            } catch {
                done(nil, Self.translate(error, identifier: identifier))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    // MARK: - Contents

    func fetchContents(for identifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        nonisolated(unsafe) let done = completionHandler
        nonisolated(unsafe) let domain = self.domain
        Task {
            do {
                let url = try await DavClient.shared.download(id: identifier.rawValue)
                let entry = try await DavClient.shared.stat(.id(identifier.rawValue))
                Self.markDownloaded(identifier.rawValue)
                // NOTE: do NOT signal .workingSet here. The extension answers the
                // working set with an empty enumerator (per the FileProvider
                // contract), so signalling it makes the system re-enumerate it,
                // see nothing, and treat every item as remotely deleted —
                // wiping local placeholders. The checkmark appears on the next
                // natural enumeration instead.
                let item: NSFileProviderItem? = entry.map { DriveItem(entry: $0) }
                done(url, item, nil)
            } catch {
                done(nil, nil, Self.translate(error, identifier: identifier))
            }
            progress.completedUnitCount = 100
        }
        return progress
    }

    // MARK: - Enumeration

    func enumerator(for identifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        // Refuse clearly when there is no credential, so Finder shows a sign-in
        // affordance instead of an empty folder that looks like an empty drive.
        guard Credentials.current != nil else {
            throw NSFileProviderError(.notAuthenticated)
        }

        // 🔴 The system asks for two SYNTHETIC containers by name, and treating
        // their identifiers as paths sends the backend nonsense:
        // "PROPFIND /dav/NSFileProviderWorkingSetContainerItemIdentifier" 404ing
        // on a loop, which is what the logs showed.
        //
        // The working set is the set of items the system keeps materialised for
        // search and recents. With no server-side change feed there is no honest
        // way to populate it, so it is honestly empty rather than wrong. Trash
        // likewise: this provider deletes for real and offers no trash.
        if identifier == .workingSet || identifier == .trashContainer {
            return EmptyEnumerator()
        }

        return DriveEnumerator(
            container: identifier == .rootContainer ? .root : .id(identifier.rawValue))
    }

    // MARK: - Writes

    /// Create a file or a folder.
    ///
    /// 🔑 The template's identifier is deliberately ignored. The header is
    /// explicit that it "is not intended to be the identifier assigned to the
    /// item by the provider", and the created item must come back carrying the
    /// identifier the provider chose. Ours comes from the backend, which mints it
    /// from the inode of the thing it just wrote.
    ///
    /// A new item has no id yet, so it is addressed as a name inside its
    /// identified parent.
    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        nonisolated(unsafe) let done = completionHandler

        let parent = itemTemplate.parentItemIdentifier
        let name = itemTemplate.filename
        let isFolder = itemTemplate.contentType == .folder
        let ref: DavClient.Ref = parent == .rootContainer
            ? .rootChild(name: name)
            : .child(parent: parent.rawValue, name: name)

        Task {
            do {
                let entry: DavEntry
                if isFolder {
                    entry = try await DavClient.shared.mkcol(ref)
                } else {
                    guard let url else {
                        // A file with no contents is still a file: create it empty
                        // rather than failing, which is what a touch does.
                        let empty = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                        FileManager.default.createFile(atPath: empty.path, contents: Data())
                        defer { try? FileManager.default.removeItem(at: empty) }
                        entry = try await DavClient.shared.put(ref, from: empty)
                        done(DriveItem(entry: entry), [], false, nil)
                        progress.completedUnitCount = 100
                        return
                    }
                    // 🔑 The system unlinks this file once the handler returns, so
                    // the upload has to finish first. It does — this is awaited.
                    entry = try await DavClient.shared.put(ref, from: url)
                }
                // Empty pending fields: everything the template asked for was
                // applied.
                done(DriveItem(entry: entry), [], false, nil)
            } catch {
                done(nil, [], false, Self.translate(error, identifier: nil))
            }
            progress.completedUnitCount = 100
        }
        return progress
    }

    /// Apply a change to an existing item.
    ///
    /// Rename, move and edit can all arrive in one call, and the id does not
    /// change for any of them — that is the whole point of identity being the
    /// inode rather than the path.
    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        nonisolated(unsafe) let done = completionHandler

        let identifier = item.itemIdentifier
        let id = identifier.rawValue
        let wantsRename = changedFields.contains(.filename)
        let wantsMove = changedFields.contains(.parentItemIdentifier)
        let wantsContent = changedFields.contains(.contents)
        let newParentIdentifier = item.parentItemIdentifier
        let newParent = newParentIdentifier == .rootContainer ? "" : newParentIdentifier.rawValue
        let newName = item.filename

        // 🔴 Fields this provider cannot store, reported as STILL PENDING rather
        // than silently swallowed. The header defines the completion handler's
        // second argument as the fields that have NOT been applied — returning
        // the applied set instead is the easy way to get this exactly backwards,
        // and nothing complains when you do.
        //
        // A plain filesystem backend has nowhere to put Finder tags, favourite
        // ranks or arbitrary extended attributes, so claiming to have saved them
        // would be a lie the system would later notice.
        let unsupported: NSFileProviderItemFields = [
            .tagData, .favoriteRank, .extendedAttributes, .typeAndCreator,
        ]
        let stillPending = changedFields.intersection(unsupported)

        Task {
            do {
                var latest: DavEntry?

                if wantsContent, let newContents {
                    // 🔴 Content and filename must be applied TOGETHER. The header
                    // warns that syncing them independently leaves the extension
                    // mismatched against the data, so the upload is addressed at
                    // the item's FINAL name in one step rather than written first
                    // and renamed after.
                    if wantsRename || wantsMove {
                        latest = try await DavClient.shared.move(
                            id: id, toParent: newParent, name: newName, overwrite: true)
                    }
                    latest = try await DavClient.shared.put(.id(id), from: newContents)
                } else if wantsRename || wantsMove {
                    latest = try await DavClient.shared.move(
                        id: id, toParent: newParent, name: newName, overwrite: true)
                }

                // Metadata-only changes the backend does not persist still need a
                // current item back, or the system has nothing to reconcile.
                // 🔑 Written out rather than with `??` — the right-hand side of a
                // nil-coalesce is an autoclosure, which cannot hold an await.
                let entry: DavEntry?
                if let latest {
                    entry = latest
                } else {
                    entry = try await DavClient.shared.stat(.id(id))
                }
                guard let entry else {
                    done(nil, [], false, Self.missing(identifier))
                    progress.completedUnitCount = 100
                    return
                }
                done(DriveItem(entry: entry), stillPending, false, nil)
            } catch {
                done(nil, [], false, Self.translate(error, identifier: identifier))
            }
            progress.completedUnitCount = 100
        }
        return progress
    }

    /// Delete for real.
    ///
    /// 🔴 A WebDAV DELETE on a collection is ALWAYS recursive. FileProvider
    /// expects a non-recursive delete unless `options` says otherwise, so a
    /// non-empty folder has to be refused here — otherwise a request to remove an
    /// empty-looking directory quietly takes its contents with it.
    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        nonisolated(unsafe) let done = completionHandler
        let id = identifier.rawValue
        let recursive = options.contains(.recursive)

        Task {
            do {
                if !recursive {
                    let entry = try await DavClient.shared.stat(.id(id))
                    if entry?.isDirectory == true {
                        let children = try await DavClient.shared.list(.id(id))
                        if !children.isEmpty {
                            done(NSFileProviderError(.directoryNotEmpty))
                            progress.completedUnitCount = 100
                            return
                        }
                    }
                }
                try await DavClient.shared.delete(id: id)
                done(nil)
            } catch {
                done(Self.translate(error, identifier: identifier))
            }
            progress.completedUnitCount = 100
        }
        return progress
    }

    // MARK: - Errors

    /// 🔴 ERROR CHOICE DECIDES WHAT THE SYSTEM DOES NEXT, not just what the user
    /// reads. From the header: an unrecognised error is treated as transient and
    /// the operation is RETRIED, and `noSuchItem` makes the system DELETE the
    /// item from disk. So a refused upload must never come back as either — the
    /// first would retry a rejected file forever, the second would destroy the
    /// user's local copy of it.
    private static func translate(_ error: Error,
                                  identifier: NSFileProviderItemIdentifier?) -> Error {
        switch error {
        case DavError.noCredentials:
            return NSFileProviderError(.notAuthenticated)
        case DavError.notFound:
            return identifier.map(missing) ?? NSFileProviderError(.noSuchItem)
        case DavError.http(let code) where code == 401 || code == 403:
            return NSFileProviderError(.notAuthenticated)
        // Any other transport-level status, and a response we could not read at
        // all, are the server being unwell rather than the request being wrong.
        // Without these two they fell through to `default`, which the header
        // treats as transient — so the system retried with generic backoff and
        // Finder showed "sent a response this client could not read" for what was
        // usually a write that had already landed.
        case DavError.http:
            return NSFileProviderError(.serverUnreachable)
        case DavError.malformedResponse:
            return NSFileProviderError(.serverUnreachable)
        case DavError.refused(let code, let detail):
            switch code {
            case 401:
                return NSFileProviderError(.notAuthenticated)
            case 403:
                // A policy refusal — a size cap, a content scan, a read-only
                // space. Not retryable and not an auth problem.
                // `cannotSynchronize` makes the system show the reason and back
                // off instead of hammering the server with something it will keep
                // refusing.
                return NSError(domain: NSFileProviderErrorDomain,
                               code: NSFileProviderError.cannotSynchronize.rawValue,
                               userInfo: [NSLocalizedDescriptionKey: detail.isEmpty
                                          ? "The server refused this change."
                                          : detail])
            case 404:
                return identifier.map(missing) ?? NSFileProviderError(.noSuchItem)
            case 405, 412:
                return NSFileProviderError(.filenameCollision)
            case 507:
                return NSFileProviderError(.insufficientQuota)
            default:
                return NSFileProviderError(.serverUnreachable)
            }
        default:
            return error
        }
    }

    /// 🔑 The header insists this be built through the category helper rather than
    /// by hand, so the offending identifier travels with the error.
    private static func missing(_ identifier: NSFileProviderItemIdentifier) -> Error {
        NSError.fileProviderErrorForNonExistentItem(withIdentifier: identifier)
    }
}
