import FileProvider
import UniformTypeIdentifiers

/// One entry in the drive, as the system wants to see it.
///
/// 🔴 IDENTIFIERS ARE OPAQUE SERVER IDS, NOT PATHS.
///
/// The first version of the provider this was extracted from used the item's
/// path as its identifier. That was wrong on two counts, and both of them matter:
///
///  1. PRIVACY. `NSFileProviderItem.h` states that "the itemIdentifier should not
///     contain sensitive information, as it may be recorded in system logs and
///     diagnostic files". That is not hypothetical — with path identifiers, 48
///     distinct real filenames out of one library were found sitting in the Mac's
///     unified log in plaintext. A filename is not a safe thing to put in a log.
///
///  2. IDENTITY. The framework lets a provider assign an identifier when an item
///     is CREATED — `NSFileProviderReplicatedExtension.h` is explicit that the
///     created item's identifier is "the identifier assigned to that item by the
///     provider rather than the identifier passed in through the template". It
///     grants no equivalent licence on modify: the header defines a modify that
///     returns a CHANGED identifier as a MERGE, after which "the system will keep
///     one of the items and remove the other one from disk". So an identifier
///     must survive a rename — and a path does not.
///
/// The reference backend's identity is (inode, birth time). It survives rename
/// and reparent because a rename does not move an inode; it changes if a file is
/// deleted and recreated, which is correct, because that is a different item.
final class DriveItem: NSObject, NSFileProviderItem {
    private let id: String
    private let parentID: String
    private let name: String
    private let isDirectory: Bool
    private let size: Int64
    private let modified: Date
    private let etag: String

    init(entry: DavEntry) {
        self.id = entry.id
        self.parentID = entry.parentID
        self.name = entry.name
        self.isDirectory = entry.isDirectory
        self.size = entry.size
        self.modified = entry.modified
        self.etag = entry.etag
    }

    /// The drive root. Synthetic — the provider answers for it without asking the
    /// backend, because the system asks for it by a fixed identifier before it
    /// knows anything else.
    init(root: Bool) {
        self.id = NSFileProviderItemIdentifier.rootContainer.rawValue
        self.parentID = ""
        self.name = "Plinth"
        self.isDirectory = true
        self.size = 0
        self.modified = Date()
        self.etag = "root"
    }

    private var isRoot: Bool { id == NSFileProviderItemIdentifier.rootContainer.rawValue }

    var itemIdentifier: NSFileProviderItemIdentifier {
        isRoot ? .rootContainer : NSFileProviderItemIdentifier(id)
    }

    /// A direct child of the drive root reports an empty parent id, which maps to
    /// the system's fixed root container rather than to any real directory.
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        parentID.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(parentID)
    }

    var filename: String { name }

    var contentType: UTType {
        if isDirectory { return .folder }
        return UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }

    var documentSize: NSNumber? { isDirectory ? nil : NSNumber(value: size) }
    var contentModificationDate: Date? { modified }
    var creationDate: Date? { modified }

    /// 🔑 Version is how the system decides whether its cached copy is stale.
    /// Content tracks the etag; metadata tracks the mtime. Getting this wrong
    /// means either endless re-downloads or files that never refresh.
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: Data(etag.utf8),
            metadataVersion: Data(String(modified.timeIntervalSince1970).utf8)
        )
    }

    /// What Finder will offer to do.
    ///
    /// 🔑 Deliberately graded rather than uniform. Advertising an operation that
    /// is guaranteed to fail is worse than having it greyed out — the user gets a
    /// menu item, a spinner, and then an error, instead of an honest no.
    ///
    /// Trashing is NOT offered. There is no provider-side trash to move an item
    /// into, and claiming one would put files somewhere the user cannot find
    /// them. Delete means delete, and Finder says so.
    var capabilities: NSFileProviderItemCapabilities {
        if isRoot {
            // The root itself cannot be renamed, reparented or deleted — there is
            // nothing above it to do any of that relative to.
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
        }
        if isDirectory {
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems,
                    .allowsRenaming, .allowsReparenting, .allowsDeleting]
        }
        return [.allowsReading, .allowsWriting, .allowsRenaming,
                .allowsReparenting, .allowsDeleting]
    }
}

// MARK: - Decoration (OneDrive-style sync badges)

extension DriveItem: NSFileProviderItemDecorating {
    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        // 对勾 = 该文件已下载到本地（materialized）
        if !isRoot && !isDirectory && FileProviderExtension.isDownloaded(id) {
            return [NSFileProviderItemDecorationIdentifier("com.quarkpan.plinth.decoration.synced")]
        }
        return nil
    }
}
