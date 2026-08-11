import Foundation

/// One entry in the drive, as the backend describes it.
struct DavEntry: Sendable {
    /// Backend-assigned stable identity. Survives rename and reparent, and never
    /// contains a filename. See `DriveItem` for why both of those matter.
    let id: String
    /// Empty for a direct child of the drive root, whose parent is the synthetic
    /// root container rather than a real directory.
    let parentID: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    let etag: String
}

enum DavError: Error, LocalizedError {
    case noCredentials
    case http(Int)
    case malformedResponse
    case notFound
    /// A write the server actively refused, with whatever it said about why.
    ///
    /// Kept distinct from `.http` because the reason matters on the write path
    /// and is worth showing. A backend may refuse an upload for policy reasons —
    /// a size cap, a content scan, a read-only space — and reporting that as a
    /// generic failure, or worse as an authentication problem, sends the user
    /// chasing something that is not wrong.
    case refused(Int, String)

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "No credential configured — open the host app and sign in."
        case .http(let code): return "The server returned HTTP \(code)."
        case .malformedResponse: return "The server sent a response this client could not read."
        case .notFound: return "That item is no longer on the server."
        case .refused(let code, let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "The server refused the change (HTTP \(code))." : trimmed
        }
    }
}

/// Minimal WebDAV client, id-addressed.
///
/// Only the verbs the drive needs are here. This is not a general WebDAV client
/// and should not grow into one.
///
/// 🔴 EVERYTHING IS ADDRESSED BY ID, NOT BY PATH. See `DriveItem` for why. The
/// backend accepts `/dav/.id/<id>` for any verb, and `/dav/.id/<parent>/<name>`
/// for something that does not exist yet, so the client never has to know or
/// send a real path.
actor DavClient {
    static let shared = DavClient()

    private var base: URL {
        Credentials.baseURL ?? URL(string: "http://127.0.0.1:8080/dav")!
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        // No URLCache: the server is the source of truth and the system does its
        // own caching. A stale cached PROPFIND shows deleted files as present.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    // MARK: - Addressing

    /// How an item is named on the wire.
    ///
    /// Nothing outside this file constructs a path. `child` exists because a file
    /// being created has no id yet — it is addressed as a name inside an
    /// identified parent, which the backend resolves in one step. `rootChild`
    /// is the same thing for the drive root, which has no id of its own.
    enum Ref: Sendable {
        case root
        case id(String)
        case child(parent: String, name: String)
        case rootChild(name: String)

        var pathComponents: [String] {
            switch self {
            case .root:                        return []
            case .id(let value):               return [".id", value]
            case .child(let parent, let name): return [".id", parent, name]
            case .rootChild(let name):         return [name]
            }
        }
    }

    /// Percent-encoding is `appendPathComponent`'s job, not ours. Hand-rolling it
    /// is how a file called "Q1 & Q2.pdf" ends up unreachable.
    private func url(for ref: Ref) -> URL {
        var url = base
        for component in ref.pathComponents { url.appendPathComponent(component) }
        return url
    }

    private func authorizedRequest(_ ref: Ref, method: String) throws -> URLRequest {
        guard let creds = Credentials.current else { throw DavError.noCredentials }
        var request = URLRequest(url: url(for: ref))
        request.httpMethod = method
        let pair = "\(creds.account):\(creds.password)"
        let encoded = Data(pair.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Reads

    /// One level of children.
    ///
    /// Depth 1 returns the container itself alongside its children. It is dropped
    /// by matching the container's own id rather than by comparing paths — which
    /// is both simpler and correct for the root, whose entry carries no id the
    /// client knows in advance.
    func list(_ ref: Ref) async throws -> [DavEntry] {
        var request = try authorizedRequest(ref, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DavError.malformedResponse }
        guard http.statusCode == 207 else { throw DavError.http(http.statusCode) }

        let containerID: String? = {
            if case .id(let value) = ref { return value }
            return nil
        }()
        let entries = PropfindParser.parse(data)
        // For a root listing the container is the first response and has no
        // parent; drop it by position rather than by id, since the client has
        // never been told the root's id.
        let rootID: String? = {
            if case .root = ref { return entries.first?.fileID }
            return nil
        }()
        return entries.compactMap { entry -> DavEntry? in
            guard !entry.fileID.isEmpty else { return nil }
            guard entry.fileID != containerID else { return nil }
            guard entry.fileID != rootID else { return nil }
            return convert(entry)
        }
    }

    /// Download to a temporary file. FileProvider hands the URL straight to the
    /// system, which moves it into place — so it must be a real file on disk, not
    /// data in memory. Files may be very large.
    func download(id: String) async throws -> URL {
        let request = try authorizedRequest(.id(id), method: "GET")
        let (temp, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw DavError.malformedResponse }
        if http.statusCode == 404 { throw DavError.notFound }
        guard (200...299).contains(http.statusCode) else { throw DavError.http(http.statusCode) }
        return temp
    }

    /// Metadata for a single item, used when the system asks about one thing
    /// rather than enumerating a whole folder.
    ///
    /// 🔴 `nil` MEANS "THE SERVER SAID THIS IS GONE", AND NOTHING ELSE.
    ///
    /// An early version collapsed every non-207 into `nil`, which the caller
    /// turns into `noSuchItem` — and per the header note in
    /// `FileProviderExtension.translate`, `noSuchItem` tells the system to delete
    /// the item from disk. So a rotated password (401) or a server hiccup (500)
    /// read as "this file no longer exists" and quietly evicted local copies of
    /// files that were sitting safely on the server the whole time.
    ///
    /// Only a 404 is an answer about the item. Everything else is an answer about
    /// the request, and belongs in the error path where `translate` can route
    /// 401/403 to `notAuthenticated` and the rest to `serverUnreachable`.
    func stat(_ ref: Ref) async throws -> DavEntry? {
        var request = try authorizedRequest(ref, method: "PROPFIND")
        request.setValue("0", forHTTPHeaderField: "Depth")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DavError.malformedResponse }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 207 else { throw DavError.http(http.statusCode) }
        // A 207 that parses to nothing is a real "not there" — the server
        // answered about the item and had nothing to say about it.
        guard let entry = PropfindParser.parse(data).first, !entry.fileID.isEmpty else { return nil }
        return convert(entry)
    }

    // MARK: - Writes

    /// Upload, overwriting whatever is there — that is what PUT means, and it is
    /// what save-in-place depends on.
    ///
    /// Streams from disk rather than loading the file: FileProvider hands over a
    /// URL to a real file precisely because documents can be enormous, and
    /// reading one into memory would defeat that.
    @discardableResult
    func put(_ ref: Ref, from local: URL) async throws -> DavEntry {
        var request = try authorizedRequest(ref, method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, fromFile: local)
        try check(response, data)
        return try await confirm(ref)
    }

    @discardableResult
    func mkcol(_ ref: Ref) async throws -> DavEntry {
        let request = try authorizedRequest(ref, method: "MKCOL")
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try await confirm(ref)
    }

    func delete(id: String) async throws {
        let request = try authorizedRequest(.id(id), method: "DELETE")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DavError.malformedResponse }
        // Already gone is the outcome the caller wanted. Treating 404 as failure
        // makes a retried delete fail forever.
        guard (200...299).contains(http.statusCode) || http.statusCode == 404 else {
            throw DavError.refused(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Rename and reparent are the same verb.
    ///
    /// The id does NOT change across this: the backend's identity is the inode,
    /// and a rename does not move an inode. That is the whole reason identity
    /// stopped being the path.
    @discardableResult
    func move(id: String, toParent parent: String, name: String, overwrite: Bool) async throws -> DavEntry {
        var request = try authorizedRequest(.id(id), method: "MOVE")
        let destination: Ref = parent.isEmpty ? .rootChild(name: name)
                                              : .child(parent: parent, name: name)
        request.setValue(url(for: destination).absoluteString, forHTTPHeaderField: "Destination")
        request.setValue(overwrite ? "T" : "F", forHTTPHeaderField: "Overwrite")
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try await confirm(.id(id))
    }

    // MARK: - Plumbing

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw DavError.malformedResponse }
        guard (200...299).contains(http.statusCode) else {
            throw DavError.refused(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Re-read an item after writing it.
    ///
    /// 🔴 The version handed back to the system has to be the version a later
    /// read would produce, or the system decides its freshly-uploaded copy is
    /// already stale and downloads it straight back. If the backend derives its
    /// etag from anything the client cannot compute — a server-side mtime, a
    /// plaintext length behind an encrypting store — then the only honest answer
    /// is to ask. One extra round trip per write.
    private func confirm(_ ref: Ref) async throws -> DavEntry {
        guard let entry = try await stat(ref) else { throw DavError.malformedResponse }
        return entry
    }

    /// The href still carries the real path; it is used ONLY to recover the
    /// display name, and never becomes an identifier.
    private func convert(_ entry: PropfindEntry) -> DavEntry {
        let decoded = entry.href.removingPercentEncoding ?? entry.href
        let name = (decoded as NSString)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .components(separatedBy: "/").last ?? ""
        return DavEntry(
            id: entry.fileID,
            parentID: entry.parentID,
            name: name,
            isDirectory: entry.isCollection,
            size: entry.length,
            modified: entry.modified,
            etag: entry.etag
        )
    }
}
