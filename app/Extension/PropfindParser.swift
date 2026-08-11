import Foundation

/// Pulls the handful of properties the drive needs out of a PROPFIND multistatus.
///
/// Written against XMLParser rather than a regex because filenames legitimately
/// contain the characters that break naive matching — spaces, ampersands, angle
/// brackets.
struct PropfindEntry {
    var href = ""
    var isCollection = false
    var length: Int64 = 0
    var modified = Date()
    var etag = ""
    /// The backend's stable identity for this item — not a path. This is what the
    /// system gets as an item identifier.
    var fileID = ""
    /// Identity of the containing folder. Empty for a direct child of the drive
    /// root, whose parent is the synthetic root container.
    var parentID = ""
}

enum PropfindParser {
    static func parse(_ data: Data) -> [PropfindEntry] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true      // the D: prefix is conventional, not required
        parser.parse()
        return delegate.entries
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [PropfindEntry] = []
        private var current: PropfindEntry?
        private var text = ""
        private var inResourceType = false

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"   // RFC 1123
            return f
        }()

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            text = ""
            switch name {
            case "response":     current = PropfindEntry()
            case "resourcetype": inResourceType = true
            // 🔑 <collection/> only means "directory" INSIDE resourcetype. It also
            // appears in supportedlock, and treating that occurrence as a
            // directory makes every file enumerate as a folder.
            case "collection" where inResourceType: current?.isCollection = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "href":              current?.href = value
            case "getcontentlength":  current?.length = Int64(value) ?? 0
            case "getlastmodified":   if let d = Self.formatter.date(from: value) { current?.modified = d }
            case "getetag":           current?.etag = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "fileid":            current?.fileID = value
            case "parentid":          current?.parentID = value
            case "resourcetype":      inResourceType = false
            case "response":          if let c = current { entries.append(c) }; current = nil
            default: break
            }
            text = ""
        }
    }
}
