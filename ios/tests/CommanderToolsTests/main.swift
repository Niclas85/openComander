import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
func refuses(_ action: () throws -> Void) {
    do { try action(); fatalError("Expected refusal") } catch { }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("OpenCommander-ToolsTests-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: false)
defer { try? fm.removeItem(at: root) }
let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
for url in [a, b, a.appendingPathComponent("sub"), b.appendingPathComponent("sub")] { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
func file(_ directory: URL, _ name: String, _ content: String) throws -> URL {
    let url = directory.appendingPathComponent(name); try Data(content.utf8).write(to: url); return url
}
let source = try file(a, "Grüsse.txt", "same")
_ = try file(b, "Grüsse.txt", "same")
_ = try file(a, "sub/diff.txt", "aaaa")
_ = try file(b, "sub/diff.txt", "bbbb")
_ = try file(a, "only.txt", "left")
_ = try file(b, "other.txt", "right")
_ = try file(a, ".hidden.txt", "hidden")
try fm.createSymbolicLink(at: a.appendingPathComponent("external"), withDestinationURL: b)
let cancel = FileOperationCancellation()
check(CommanderTools.searchDirectory("relative/path") == nil, "Relative search paths refused")
check(CommanderTools.searchDirectory("") == nil, "Empty search path refused")
check(CommanderTools.searchDirectory("https://example.com") == nil, "Web URL is not a filesystem search path")
check(CommanderTools.searchDirectory("~/Downloads")?.path.hasSuffix("/Downloads") == true, "Home path expands")
check(CommanderTools.searchDirectory(a.path)?.path == a.path, "Active pane absolute path preserved")
let changedPath = CommanderTools.searchDirectory(b.path)!
let changedResults = try CommanderTools.search(changedPath, query: "other.txt", hidden: false, cancel: cancel)
check(changedResults.urls.map { $0.resolvingSymlinksInPath().path } == [b.appendingPathComponent("other.txt").resolvingSymlinksInPath().path], "Changed dialog path searches chosen folder")
let search = try CommanderTools.search(a, query: "*.TXT", hidden: false, cancel: cancel)
check(search.urls.count == 3, "Recursive wildcard, case insensitive, hidden omitted, no link traversal")
let unicode = try CommanderTools.search(a, query: "GRÜ", hidden: false, cancel: cancel)
check(unicode.urls.count == 1, "Unicode substring")
let sensitiveGlob = try CommanderTools.search(a, query: "*.TXT", hidden: false, caseSensitive: true, cancel: cancel)
check(sensitiveGlob.urls.isEmpty, "Case-sensitive wildcard rejects differently cased extension")
let sensitiveMismatch = try CommanderTools.search(a, query: "GRÜ", hidden: false, caseSensitive: true, cancel: cancel)
check(sensitiveMismatch.urls.isEmpty, "Case-sensitive substring rejects uppercase mismatch")
let sensitiveUnicode = try CommanderTools.search(a, query: "Gru\u{0308}", hidden: false, caseSensitive: true, cancel: cancel)
check(sensitiveUnicode.urls.count == 1, "Case-sensitive substring preserves canonical Unicode matching")
let sensitiveMatch = try CommanderTools.search(a, query: "Gr?ss*.txt", hidden: false, caseSensitive: true, cancel: cancel)
check(sensitiveMatch.urls.count == 1, "Case-sensitive glob matches exact case with both wildcards")
let hidden = try CommanderTools.search(a, query: "hidden", hidden: true, cancel: cancel)
check(hidden.urls.count == 1, "Hidden opt-in")
refuses { _ = try CommanderTools.scan(a, hidden: true, cancel: cancel, limit: 1) }
cancel.cancel(); refuses { _ = try CommanderTools.search(a, query: "*", hidden: false, cancel: cancel) }; cancel.reset()
print("PASS recursive search, globs, Unicode, hidden setting, symlinks, bounds and cancellation")
let comparison = try CommanderTools.compare(a, b, hidden: false, cancel: cancel)
check(comparison.rows.first { $0.path == "Grüsse.txt" }?.state == .equal, "Content equality")
check(comparison.rows.first { $0.path == "sub/diff.txt" }?.state == .different, "Same-size different bytes detected")
check(comparison.rows.first { $0.path == "only.txt" }?.state == .leftOnly, "Only left")
check(comparison.rows.first { $0.path == "other.txt" }?.state == .rightOnly, "Only right")
check(comparison.rows.first { $0.path == "external" }?.state == .leftOnly, "Link not traversed")
check(comparison.warnings.isEmpty, "No hidden scan failures")
print("PASS content comparison, equal, changed, only-left/right and link safety")
let another = try file(a, "second.txt", "second")
let plan = try CommanderTools.renamePlan([source, another], rule: .init(pattern: "Foto-[C]-[N][E]", start: 7, digits: 2))
check(plan.map { $0.destination.lastPathComponent } == ["Foto-07-Grüsse.txt", "Foto-08-second.txt"], "Preview tokens/counter")
check(fm.fileExists(atPath: source.path), "Preview never renames")
let records = try CommanderTools.rename(plan, cancel: cancel)
check(records.count == 2 && !fm.fileExists(atPath: source.path), "Batch rename executes")
for record in records.reversed() { try record.undo(move: true) }
check(fm.fileExists(atPath: source.path) && fm.fileExists(atPath: another.path), "History undo restores originals")
let rollbackPlan = try CommanderTools.renamePlan([source, another], rule: .init(pattern: "rollback-[C][E]"))
var moves = 0
refuses {
    _ = try CommanderTools.rename(rollbackPlan, cancel: cancel, move: { source, destination in
        moves += 1
        if moves == 2 { throw CocoaError(.fileWriteNoPermission) }
        try fm.moveItem(at: source, to: destination)
    })
}
check(moves == 2 && fm.fileExists(atPath: source.path) && fm.fileExists(atPath: another.path), "Failed second rename rolls back first")
refuses {
    _ = try CommanderTools.rename(rollbackPlan, cancel: cancel, move: { source, destination in
        try fm.moveItem(at: source, to: destination); cancel.cancel()
    })
}
check(fm.fileExists(atPath: source.path) && fm.fileExists(atPath: another.path), "Cancellation rolls back completed rename")
cancel.reset()
let race = try CommanderTools.renamePlan([source, another], rule: .init(pattern: "race-[C][E]"))
try Data("unrelated".utf8).write(to: race[1].destination)
refuses { _ = try CommanderTools.rename(race, cancel: cancel) }
check(fm.fileExists(atPath: source.path), "New collision detected before mutating first file")
refuses { _ = try CommanderTools.renamePlan([source, another], rule: .init(pattern: "same.txt")) }
refuses { _ = try CommanderTools.renamePlan([source], rule: .init(pattern: "only.txt")) }
refuses { _ = try CommanderTools.renamePlan([source], rule: .init(pattern: "../escape")) }
refuses { _ = try CommanderTools.renamePlan([source], rule: .init(pattern: ".")) }
refuses { _ = try CommanderTools.renamePlan([source], rule: .init(start: -1)) }
refuses { _ = try CommanderTools.renamePlan([source], rule: .init(start: Int.max)) }
let literal = try file(a, "[C].txt", "literal")
let literalPlan = try CommanderTools.renamePlan([literal], rule: .init())
check(literalPlan[0].destination.lastPathComponent == "[C].txt", "Tokens within original names stay literal")
let stale = try CommanderTools.renamePlan([source], rule: .init(pattern: "changed[E]"))
try Data("edited".utf8).write(to: source)
refuses { _ = try CommanderTools.rename(stale, cancel: cancel) }
check(fm.fileExists(atPath: source.path), "Stale preview preserves source")
cancel.cancel(); refuses { _ = try CommanderTools.rename(try CommanderTools.renamePlan([another], rule: .init(pattern: "cancel[E]")), cancel: cancel) }
check(fm.fileExists(atPath: another.path), "Cancelled rename preserves source")
print("PASS rename preview, counters, undo, collisions, invalid names, literal tokens, stale previews and cancellation")
