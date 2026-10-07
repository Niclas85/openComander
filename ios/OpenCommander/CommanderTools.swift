import Foundation
import CryptoKit

/// Read-only, bounded traversal. Never follows directory links or hides access errors.
enum CommanderTools {
    /// A dialog path is absolute (or ~/...), never relative to the process CWD.
    static func searchDirectory(_ path: String) -> URL? {
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }
    struct Scan {
        var entries: [String: URL] = [:]
        var warnings: [String] = []
    }
    static func scan(_ root: URL, hidden: Bool, cancel: FileOperationCancellation,
                     limit: Int = 100_000) throws -> Scan {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
        var result = Scan()
        let base = root.standardizedFileURL.path
        guard let iterator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: hidden ? [] : [.skipsHiddenFiles], errorHandler: { url, error in
                result.warnings.append(url.path + ": " + error.localizedDescription); return true
            }) else { throw CocoaError(.fileReadNoPermission) }
        for case let url as URL in iterator {
            try cancel.check()
            guard result.entries.count < limit else { throw failure("Limit: \(limit) entries") }
            result.entries[String(url.standardizedFileURL.path.dropFirst(base.count + (base == "/" ? 0 : 1)))] = url
        }
        return result
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "OpenCommander.Tools", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func search(_ root: URL, query: String, hidden: Bool, cancel: FileOperationCancellation) throws -> (urls: [URL], warnings: [String]) {
        let scan = try scan(root, hidden: hidden, cancel: cancel)
        // Plain text matches part of a name; * and ? use anchored glob semantics.
        let normalized = query.precomposedStringWithCanonicalMapping
        let wildcard = normalized.contains("*") || normalized.contains("?")
        let expression = NSRegularExpression.escapedPattern(for: normalized)
            .replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".")
        let regex = try NSRegularExpression(pattern: wildcard ? "^" + expression + "$" : expression, options: .caseInsensitive)
        var urls: [URL] = []
        for (_, url) in scan.entries.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
            try cancel.check()
            let name = url.lastPathComponent.precomposedStringWithCanonicalMapping
            if regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil { urls.append(url) }
        }
        return (urls, scan.warnings)
    }
    static func digest(_ url: URL, cancel: FileOperationCancellation) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try cancel.check()
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return Data(hash.finalize())
    }
    struct Comparison {
        enum State { case equal, different, leftOnly, rightOnly, unreadable }
        let path: String
        let state: State
        let detail: String
    }
    static func compare(_ left: URL, _ right: URL, hidden: Bool, cancel: FileOperationCancellation) throws -> (rows: [Comparison], warnings: [String]) {
        let a = try scan(left, hidden: hidden, cancel: cancel)
        let b = try scan(right, hidden: hidden, cancel: cancel)
        var rows: [Comparison] = []
        for path in Set(a.entries.keys).union(b.entries.keys).sorted() {
            try cancel.check()
            guard let l = a.entries[path] else { rows.append(.init(path: path, state: .rightOnly, detail: "")); continue }
            guard let r = b.entries[path] else { rows.append(.init(path: path, state: .leftOnly, detail: "")); continue }
            do {
                let beforeL = try identity(l), beforeR = try identity(r)
                let la = try FileManager.default.attributesOfItem(atPath: l.path)
                let ra = try FileManager.default.attributesOfItem(atPath: r.path)
                let lt = la[.type] as? FileAttributeType, rt = ra[.type] as? FileAttributeType
                let equal: Bool
                if lt != rt { equal = false }
                else if lt == .typeDirectory { continue } // descendants are compared individually
                else if lt == .typeSymbolicLink {
                    equal = try FileManager.default.destinationOfSymbolicLink(atPath: l.path) == FileManager.default.destinationOfSymbolicLink(atPath: r.path)
                } else if lt == .typeRegular {
                    if (la[.size] as? NSNumber) != (ra[.size] as? NSNumber) { equal = false }
                    else { equal = try digest(l, cancel: cancel) == digest(r, cancel: cancel) }
                } else { throw failure("Unsupported file type") }
                guard beforeL == (try identity(l)), beforeR == (try identity(r)) else { throw failure("File changed during comparison") }
                rows.append(.init(path: path, state: equal ? .equal : .different, detail: ""))
            } catch {
                try cancel.check()
                rows.append(.init(path: path, state: .unreadable, detail: error.localizedDescription))
            }
        }
        return (rows, a.warnings + b.warnings)
    }
    static func identity(_ url: URL) throws -> String {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return [a[.systemNumber], a[.systemFileNumber], a[.type], a[.size], a[.modificationDate]].map { String(describing: $0) }.joined(separator: "|")
    }
    struct RenameRule {
        var pattern = "[N][E]"
        var find = ""
        var replacement = ""
        var start = 1
        var digits = 3
    }
    struct Rename {
        let source: URL
        let destination: URL
        let identity: String
    }
    static func renamePlan(_ urls: [URL], rule: RenameRule) throws -> [Rename] {
        guard !urls.isEmpty, urls.count <= 10_000, rule.start >= 0, rule.start <= Int.max - urls.count,
              (1...9).contains(rule.digits) else { throw failure("Invalid selection / counter") }
        var seen = Set<String>()
        var plan: [Rename] = []
        for (i, url) in urls.enumerated() {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let folder = attributes[.type] as? FileAttributeType == .typeDirectory
            let ext = folder ? "" : url.pathExtension
            let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
            // Single-pass expansion: brackets inside original filenames stay literal.
            let regex = try NSRegularExpression(pattern: "\\[(N|E|C)\\]")
            let template = rule.pattern
            var name = template
            for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
                let token = (template as NSString).substring(with: match.range)
                let value = token == "[N]" ? stem : token == "[E]" ? (ext.isEmpty ? "" : "." + ext) : String(format: "%0*d", rule.digits, rule.start + i)
                name = (name as NSString).replacingCharacters(in: match.range, with: value)
            }
            if !rule.find.isEmpty { name = name.replacingOccurrences(of: rule.find, with: rule.replacement) }
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0"), name.utf8.count <= 255 else { throw failure("Invalid name: " + name) }
            let destination = url.deletingLastPathComponent().appendingPathComponent(name)
            let key = destination.path.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(key).inserted else { throw failure("Duplicate destination: " + name) }
            // Conservatively refuse occupied names, including other selected sources.
            // Only exact no-ops are permitted; case-only rename needs volume-specific handling.
            if destination.path != url.path && SafeFileOperations.exists(destination) { throw failure("Destination exists: " + name) }
            plan.append(.init(source: url, destination: destination, identity: try identity(url)))
        }
        return plan
    }
    static func rename(_ plan: [Rename], cancel: FileOperationCancellation,
                       move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws -> [FileUndoRecord] {
        let fm = FileManager.default
        var done: [Rename] = []
        do {
            for row in plan {
                try cancel.check()
                guard row.identity == (try identity(row.source)) else { throw failure("Source changed: " + row.source.path) }
                if row.source.path == row.destination.path { continue }
                guard !SafeFileOperations.exists(row.destination) else { throw failure("Destination exists: " + row.destination.path) }
            }
            for row in plan where row.source.path != row.destination.path {
                try cancel.check()
                guard row.identity == (try identity(row.source)) else { throw failure("Source changed: " + row.source.path) }
                try move(row.source, row.destination)
                done.append(row)
            }
        } catch {
            var failures: [String] = []
            for row in done.reversed() {
                do {
                    guard !SafeFileOperations.exists(row.source), row.identity == (try identity(row.destination)) else { throw failure("Changed during rollback") }
                    try fm.moveItem(at: row.destination, to: row.source)
                } catch { failures.append(row.destination.path + ": " + error.localizedDescription) }
            }
            if !failures.isEmpty { throw failure(error.localizedDescription + "\nRollback incomplete:\n" + failures.joined(separator: "\n")) }
            throw error
        }
        return done.map { FileUndoRecord(source: $0.source, destination: $0.destination, replacedBackup: nil) }
    }
}
