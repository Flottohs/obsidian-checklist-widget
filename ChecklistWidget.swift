// Desktop checklist widget for an Obsidian Worklist folder.
// The folder is set by the "location:" line in worklist-location.txt next to this file.
// Shows the newest YYYY-MM-DD note there (named after the day it's for; tomorrow's is
// created at 8pm so it can be planned the night before) at the middle-right of the
// desktop, grouped by the note's "## " sections, and edits its "- [ ]" lines in place.
// Notes are created from the vault's Daily template, and the current note is
// re-shaped whenever that template changes (keeping its tasks).

import AppKit
import SwiftUI
import Observation

// MARK: - Config

enum Config {
    static let templateName = "Daily template.md"
    static let fallbackTemplate = """
        ---
        tags:
        aliases: []
        type:
        status:
        date_created:
        url:
        links:
        ---



        - [ ] \n    \n- [ ] \n    \n- [ ] \n
        """
    static let width: CGFloat = 300
    static let margin: CGFloat = 24
    static let cornerRadius: CGFloat = 18
    static let pollInterval: TimeInterval = 1.5
    static let rolloverHour = 20  // 8pm: tomorrow's note gets created
}

/// A Worklist folder and the Obsidian vault it sits in.
struct WorklistLocation {
    let folder: URL
    let vault: URL?

    init(folder: URL) {
        self.folder = folder
        vault = Self.findVault(containing: folder)
    }

    enum Problem: LocalizedError {
        case unreadable(path: String, reason: String)
        case noLocationLine
        case folderMissing(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let path, let reason): return "Can't read \(path)\n\(reason)"
            case .noLocationLine: return "Add a line like \"location: /path/to/Worklist\" to worklist-location.txt"
            case .folderMissing(let path): return "Worklist folder not found:\n\(path)\nUpdate worklist-location.txt"
            }
        }
    }

    private static let prefix = "location:"

    /// The folder named on the "location:" line of the file (it may not exist).
    static func configuredFolder(in file: URL) throws -> URL {
        let text: String
        do { text = try String(contentsOf: file, encoding: .utf8) }
        catch {
            let reason = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription
            throw Problem.unreadable(path: file.path, reason: reason ?? error.localizedDescription)
        }
        guard let line = text.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.lowercased().hasPrefix(prefix) })
        else { throw Problem.noLocationLine }
        var path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") { path = String(path.dropFirst().dropLast()) }
        guard !path.isEmpty else { throw Problem.noLocationLine }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// Rewrites the "location:" line, keeping any other lines in the file.
    static func setConfiguredFolder(_ folder: URL, in file: URL) throws {
        let newLine = "\(prefix) \(folder.path)"
        var lines = (try? String(contentsOf: file, encoding: .utf8))?.components(separatedBy: "\n") ?? []
        if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(prefix) }) {
            lines[i] = newLine
        } else {
            lines.insert(newLine, at: 0)
        }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// Nearest enclosing folder with a .obsidian directory.
    private static func findVault(containing folder: URL) -> URL? {
        var dir = folder
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".obsidian").path) { return dir }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// The daily template in the vault's Templates folder: "Daily template.md" if present,
    /// otherwise any note there with "daily" in its name (so renaming it doesn't break things).
    var template: URL? {
        guard let vault,
              let data = try? Data(contentsOf: vault.appendingPathComponent(".obsidian/templates.json")),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folderName = settings["folder"] as? String
        else { return nil }
        let folder = vault.appendingPathComponent(folderName)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        let notes = names.filter { $0.lowercased().hasSuffix(".md") }.sorted()
        let name = notes.first { $0.lowercased() == Config.templateName.lowercased() }
            ?? notes.first { $0.lowercased().contains("daily") }
        return name.map { folder.appendingPathComponent($0) }
    }
}

/// Works out the Worklist folder on each refresh, and recovers when things move:
/// - the location file is followed by bookmark if its folder (e.g. Developer) is moved,
/// - the Worklist folder is followed by bookmark if it's moved, and the file is corrected,
/// - if the file can't be read at all, the last folder that worked keeps being used.
@MainActor
final class LocationResolver {
    private var locationFile = URL(fileURLWithPath: locationFilePath)
    private var lastGood: WorklistLocation?
    private var lastWarning: String?
    private let defaults = UserDefaults.standard
    private let fileBookmarkKey = "locationFileBookmark"
    private let folderBookmarkKey = "worklistFolderBookmark"
    private let folderPathKey = "worklistFolderPath"

    func resolve() throws -> WorklistLocation {
        let fm = FileManager.default
        if !fm.isReadableFile(atPath: locationFile.path),
           let moved = Self.follow(defaults.data(forKey: fileBookmarkKey)), moved != locationFile {
            warn("location file moved to \(moved.path)")
            locationFile = moved
        }

        let configured: URL
        do {
            configured = try WorklistLocation.configuredFolder(in: locationFile)
        } catch {
            // Keep going with the last folder that worked rather than blanking the widget.
            if let fallback = lastGood?.folder ?? Self.follow(defaults.data(forKey: folderBookmarkKey)),
               Self.isDirectory(fallback) {
                warn("\(error.localizedDescription) - using last known folder \(fallback.path)")
                return remember(fallback, healthy: false)
            }
            throw error
        }

        if Self.isDirectory(configured) { return remember(configured) }

        // Only follow a moved folder when the file still names where it used to be,
        // so a deliberate edit to the file is never overwritten.
        if configured.path == defaults.string(forKey: folderPathKey),
           let moved = Self.follow(defaults.data(forKey: folderBookmarkKey)), Self.isDirectory(moved) {
            warn("Worklist moved to \(moved.path) - updating \(locationFile.lastPathComponent)")
            try? WorklistLocation.setConfiguredFolder(moved, in: locationFile)
            return remember(moved)
        }
        throw WorklistLocation.Problem.folderMissing(configured.path)
    }

    private func remember(_ folder: URL, healthy: Bool = true) -> WorklistLocation {
        if lastGood?.folder != folder {
            lastGood = WorklistLocation(folder: folder)
            if let data = try? folder.bookmarkData() { defaults.set(data, forKey: folderBookmarkKey) }
            defaults.set(folder.path, forKey: folderPathKey)
        }
        if healthy {
            if let data = try? locationFile.bookmarkData() { defaults.set(data, forKey: fileBookmarkKey) }
            if lastWarning != nil { log("location file readable again"); lastWarning = nil }
        }
        return lastGood!
    }

    /// Logs each distinct problem once, until things are healthy again.
    private func warn(_ message: String) {
        if message != lastWarning { log(message); lastWarning = message }
    }

    private static func follow(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              !url.path.contains("/.Trash/")
        else { return nil }
        return url.standardizedFileURL
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

func log(_ message: String) {
    print("[\(Date())] \(message)")
    fflush(stdout)
}

// MARK: - Markdown

struct TaskItem: Identifiable, Equatable {
    let id: Int          // ordinal among the note's tasks
    let lineIndex: Int
    let done: Bool
    let text: String
    var isBlank: Bool { text.isEmpty }
}

struct Section: Identifiable, Equatable {
    let id: Int          // ordinal; 0 is whatever comes before the first heading
    let title: String?
    let headingLine: Int?
    var tasks: [TaskItem]
}

enum Markdown {
    // prefix "- [", mark, "] ", text
    static let taskRegex = try! NSRegularExpression(pattern: #"^(\s*[-*+] \[)([ xX])(\] ?)(.*)$"#)
    static let headingRegex = try! NSRegularExpression(pattern: #"^#{1,6}\s+(.*?)\s*$"#)

    struct Task { let done: Bool; let text: String }

    static func task(in line: String) -> Task? {
        let ns = line as NSString
        guard let m = taskRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Task(done: ns.substring(with: m.range(at: 2)) != " ",
                    text: ns.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces))
    }

    /// Heading text without the #s or a trailing colon.
    static func heading(in line: String) -> String? {
        let ns = line as NSString
        guard let m = headingRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var title = ns.substring(with: m.range(at: 1))
        while title.hasSuffix(":") { title.removeLast() }
        return title.trimmingCharacters(in: .whitespaces)
    }

    /// Index of the first line after the YAML frontmatter (0 if there is none).
    static func bodyStart(_ lines: [String]) -> Int {
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return 0 }
        return end + 1
    }

    static func sections(_ lines: [String]) -> [Section] {
        var sections = [Section(id: 0, title: nil, headingLine: nil, tasks: [])]
        var taskCount = 0
        for index in bodyStart(lines)..<lines.count {
            let line = lines[index]
            if let title = heading(in: line) {
                sections.append(Section(id: sections.count, title: title, headingLine: index, tasks: []))
            } else if let task = task(in: line) {
                sections[sections.count - 1].tasks.append(
                    TaskItem(id: taskCount, lineIndex: index, done: task.done, text: task.text))
                taskCount += 1
            }
        }
        return sections
    }

    /// Rewrites only the checkbox mark and/or text of a task line, keeping its indent and bullet.
    static func rewrite(_ line: String, done: Bool? = nil, text: String? = nil) -> String {
        let ns = line as NSString
        guard let m = taskRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return line }
        let prefix = ns.substring(with: m.range(at: 1))
        let mark = done.map { $0 ? "x" : " " } ?? ns.substring(with: m.range(at: 2))
        let close = text == nil ? ns.substring(with: m.range(at: 3)) : "] "
        let body = text ?? ns.substring(with: m.range(at: 4))
        return prefix + mark + close + body
    }

    // MARK: Template merge

    private struct Chunk {
        let key: String          // normalised heading, "" before the first heading
        let headingLine: String?
        var lines: [String]
    }

    private static func key(_ title: String?) -> String { (title ?? "").lowercased() }

    private static func chunks(_ lines: [String]) -> [Chunk] {
        var chunks = [Chunk(key: "", headingLine: nil, lines: [])]
        for line in lines.dropFirst(bodyStart(lines)) {
            if let title = heading(in: line) {
                chunks.append(Chunk(key: key(title), headingLine: line, lines: []))
            } else {
                chunks[chunks.count - 1].lines.append(line)
            }
        }
        return chunks
    }

    /// Lays the note out like the template: the template's sections in its order and format,
    /// with the note's tasks kept in their matching sections (ticks preserved, filling the
    /// template's empty slots first). Sections the template doesn't have are kept at the end,
    /// and the note's own frontmatter is kept. No task is ever dropped.
    static func merge(template: String, into note: String) -> String {
        let templateLines = template.components(separatedBy: "\n")
        let noteLines = note.components(separatedBy: "\n")
        let templateChunks = chunks(templateLines)
        let noteChunks = chunks(noteLines)

        // The note's filled tasks, grouped by section.
        var pools: [String: [Task]] = [:]
        for chunk in noteChunks {
            pools[chunk.key, default: []] += chunk.lines.compactMap(task(in:)).filter { !$0.text.isEmpty }
        }
        // Tasks from before any heading go into the template's first section that has tasks.
        let hasTaskLines: (Chunk) -> Bool = { $0.lines.contains { task(in: $0) != nil } }
        if !(templateChunks.first.map(hasTaskLines) ?? false),
           let target = templateChunks.first(where: hasTaskLines)?.key,
           let loose = pools.removeValue(forKey: "") {
            pools[target] = loose + (pools[target] ?? [])
        }

        var body: [String] = []
        var templateKeys = Set<String>()
        for chunk in templateChunks {
            templateKeys.insert(chunk.key)
            var pool = pools[chunk.key] ?? []
            let fixed = Set(chunk.lines.compactMap(task(in:)).map { $0.text.lowercased() }.filter { !$0.isEmpty })
            var out: [String] = []
            for line in chunk.lines {
                guard let slot = task(in: line) else { out.append(line); continue }
                if !slot.text.isEmpty {
                    // A task the template always has: keep the note's tick for it.
                    if let i = pool.firstIndex(where: { $0.text.lowercased() == slot.text.lowercased() }) {
                        out.append(rewrite(line, done: pool.remove(at: i).done))
                    } else {
                        out.append(line)
                    }
                } else if let i = pool.firstIndex(where: { !fixed.contains($0.text.lowercased()) }) {
                    let task = pool.remove(at: i)
                    out.append(rewrite(line, done: task.done, text: task.text))
                } else {
                    out.append(line)
                }
            }
            // More tasks than empty slots: add them after the section's last task.
            let extras = pool.filter { !fixed.contains($0.text.lowercased()) }
            if !extras.isEmpty {
                let at = (out.lastIndex { task(in: $0) != nil }).map { $0 + 1 } ?? 0
                out.insert(contentsOf: extras.map { "- [\($0.done ? "x" : " ")] \($0.text)" }, at: at)
            }
            if let heading = chunk.headingLine { body.append(heading) }
            body += out
        }

        // Keep anything in sections the template no longer has.
        for chunk in noteChunks where !templateKeys.contains(chunk.key) {
            guard chunk.lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            if let heading = chunk.headingLine { body.append(heading) }
            body += chunk.lines
        }

        let noteStart = bodyStart(noteLines)
        let frontmatter = noteStart > 0
            ? Array(noteLines[..<noteStart])
            : Array(templateLines[..<bodyStart(templateLines)])
        return (frontmatter + body).joined(separator: "\n")
    }
}

// MARK: - Model

@MainActor @Observable
final class NoteStore {
    private(set) var noteURL: URL?
    private(set) var sections: [Section] = []
    private(set) var errorMessage: String?
    var tasks: [TaskItem] { sections.flatMap(\.tasks) }

    @ObservationIgnored var isEditing: () -> Bool = { false }
    @ObservationIgnored private var loadedModified: Date?
    @ObservationIgnored private var location: WorklistLocation?
    @ObservationIgnored private let resolver = LocationResolver()
    @ObservationIgnored private var templateWarning: String?
    /// Template text last applied to each recent note, so a note is only re-shaped when the template changes.
    @ObservationIgnored private let appliedTemplatesKey = "appliedTemplates"

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Start of the current day; observed so the Today/Tomorrow label redraws at midnight.
    private(set) var today = Calendar.current.startOfDay(for: Date())

    /// Notes are named after the day they're for.
    var planDate: Date? {
        noteURL.flatMap { Self.dayFormatter.date(from: $0.deletingPathExtension().lastPathComponent) }
    }

    /// The note that should exist by now: tomorrow's from the rollover hour on, otherwise today's.
    static func currentNoteName(now: Date = Date()) -> String {
        let calendar = Calendar.current
        let day = calendar.component(.hour, from: now) >= Config.rolloverHour
            ? calendar.date(byAdding: .day, value: 1, to: now)!
            : now
        return dayFormatter.string(from: day) + ".md"
    }

    // MARK: Loading

    func refresh(force: Bool = false) {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        if startOfToday != today { today = startOfToday }
        guard force || !isEditing() else { return }
        do {
            let location = try resolver.resolve()
            self.location = location
            let template = readTemplate(location)
            let url = try resolveNote(in: location, template: template)
            if let template { try syncWithTemplate(template, note: url) }
            let modified = Self.modificationDate(of: url)
            if force || url != noteURL || modified != loadedModified {
                try load(url)
            }
            if errorMessage != nil { errorMessage = nil }
        } catch {
            if error is WorklistLocation.Problem, noteURL != nil {
                noteURL = nil
                sections = []
                loadedModified = nil
            }
            let message = error.localizedDescription
            if message != errorMessage {
                errorMessage = message
                log("refresh failed: \(message)")
            }
        }
    }

    private func readTemplate(_ location: WorklistLocation) -> String? {
        let text = location.template.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let warning = text == nil ? "no daily template found - using a plain checklist" : nil
        if warning != templateWarning {
            log(warning ?? "using template \(location.template?.lastPathComponent ?? "")")
            templateWarning = warning
        }
        return text
    }

    /// Newest dated note in the folder; creates the current one from the template if nothing is that new.
    private func resolveNote(in location: WorklistLocation, template: String?) throws -> URL {
        let fm = FileManager.default
        let dated = try fm.contentsOfDirectory(atPath: location.folder.path)
            .filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}\.md$"#, options: .regularExpression) != nil }
            .sorted()
        let currentName = Self.currentNoteName()
        if let newest = dated.last, newest >= currentName {
            return location.folder.appendingPathComponent(newest)
        }
        let url = location.folder.appendingPathComponent(currentName)
        if !fm.fileExists(atPath: url.path) {
            try (template ?? Config.fallbackTemplate).write(to: url, atomically: true, encoding: .utf8)
            if let template { recordApplied(template, to: currentName) }
            log("created \(currentName)")
        }
        return url
    }

    /// Re-shapes today's or a future note to the template when the template has changed since.
    private func syncWithTemplate(_ template: String, note url: URL) throws {
        let name = url.lastPathComponent
        guard name >= Self.dayFormatter.string(from: today) + ".md" else { return }
        var applied = UserDefaults.standard.dictionary(forKey: appliedTemplatesKey) as? [String: String] ?? [:]
        guard applied[name] != template else { return }
        let original = try String(contentsOf: url, encoding: .utf8)
        let merged = Markdown.merge(template: template, into: original)
        if merged != original {
            try merged.write(to: url, atomically: true, encoding: .utf8)
            log("updated \(name) to match the template")
        }
        applied[name] = template
        UserDefaults.standard.set(applied, forKey: appliedTemplatesKey)
    }

    private func recordApplied(_ template: String, to name: String) {
        var applied = UserDefaults.standard.dictionary(forKey: appliedTemplatesKey) as? [String: String] ?? [:]
        applied[name] = template
        // Only recent notes matter.
        for key in applied.keys.sorted().dropLast(14) { applied.removeValue(forKey: key) }
        UserDefaults.standard.set(applied, forKey: appliedTemplatesKey)
    }

    private func load(_ url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = Markdown.sections(text.components(separatedBy: "\n"))
        if url != noteURL { noteURL = url; log("showing \(url.lastPathComponent)") }
        if parsed != sections { sections = parsed }
        loadedModified = Self.modificationDate(of: url)
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Edits

    /// Re-reads the file, applies the change to its lines, writes it back and reloads.
    private func mutate(_ change: (inout [String], [Section]) -> Void) {
        guard let url = noteURL else { return }
        do {
            let original = try String(contentsOf: url, encoding: .utf8)
            var lines = original.components(separatedBy: "\n")
            change(&lines, Markdown.sections(lines))
            let updated = lines.joined(separator: "\n")
            if updated != original {
                try updated.write(to: url, atomically: true, encoding: .utf8)
            }
            try load(url)
        } catch {
            errorMessage = error.localizedDescription
            log("write failed: \(error)")
        }
    }

    func toggle(_ id: Int) {
        mutate { lines, sections in
            guard let task = sections.flatMap(\.tasks).first(where: { $0.id == id }), !task.isBlank else { return }
            lines[task.lineIndex] = Markdown.rewrite(lines[task.lineIndex], done: !task.done)
        }
    }

    func setText(_ id: Int, _ text: String) {
        let clean = Self.sanitize(text)
        mutate { lines, sections in
            guard let task = sections.flatMap(\.tasks).first(where: { $0.id == id }), task.text != clean else { return }
            lines[task.lineIndex] = Markdown.rewrite(lines[task.lineIndex], done: clean.isEmpty ? false : nil, text: clean)
        }
    }

    func delete(_ id: Int) {
        mutate { lines, sections in
            guard let task = sections.flatMap(\.tasks).first(where: { $0.id == id }) else { return }
            let i = task.lineIndex
            func isSpacer(_ j: Int) -> Bool { j >= 0 && j < lines.count && lines[j].trimmingCharacters(in: .whitespaces).isEmpty }
            // Take the template's spacer line with it so gaps don't pile up.
            if isSpacer(i + 1) && isSpacer(i - 1) { lines.remove(at: i + 1) }
            lines.remove(at: i)
        }
    }

    /// Fills the section's first empty slot after its last filled task, otherwise adds a line
    /// after its last task (or straight under its heading).
    func add(_ text: String, to sectionID: Int) {
        let clean = Self.sanitize(text)
        guard !clean.isEmpty else { return }
        mutate { lines, sections in
            guard let section = sections.first(where: { $0.id == sectionID }) else { return }
            let lastFilled = section.tasks.last(where: { !$0.isBlank })?.id ?? -1
            if let blank = section.tasks.first(where: { $0.isBlank && $0.id > lastFilled }) {
                lines[blank.lineIndex] = Markdown.rewrite(lines[blank.lineIndex], done: false, text: clean)
            } else if let last = section.tasks.last {
                let indent = String(lines[last.lineIndex].prefix { $0 == " " || $0 == "\t" })
                lines.insert(indent + "- [ ] " + clean, at: last.lineIndex + 1)
            } else if let heading = section.headingLine {
                lines.insert("- [ ] " + clean, at: heading + 1)
            } else if lines.last == "" {
                lines.insert("- [ ] " + clean, at: lines.count - 1)
            } else {
                lines.append("- [ ] " + clean)
            }
        }
    }

    func openInObsidian() {
        guard let url = noteURL, let vault = location?.vault else { return }
        let fileInVault = url.deletingPathExtension().path.dropFirst(vault.path.count + 1)
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "vault", value: vault.lastPathComponent),
            URLQueryItem(name: "file", value: String(fileInVault)),
        ]
        if let link = components.url { NSWorkspace.shared.open(link) }
    }
}

// MARK: - Views

struct ChecklistView: View {
    let store: NoteStore
    let onHeightChange: (CGFloat) -> Void

    private var filled: [TaskItem] { store.tasks.filter { !$0.isBlank } }
    private var doneCount: Int { filled.filter(\.done).count }

    /// Headed sections always show; the bit before the first heading only if it has tasks.
    private var visibleSections: [Section] {
        let hasHeadings = store.sections.contains { $0.title != nil }
        return store.sections.filter { section in
            section.title != nil || !hasHeadings || section.tasks.contains { !$0.isBlank }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = store.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(visibleSections) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        if let title = section.title {
                            Text(title.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .kerning(0.6)
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 2)
                        }
                        ForEach(section.tasks.filter { !$0.isBlank }) { task in
                            TaskRow(task: task, store: store)
                        }
                        AddRow(store: store, sectionID: section.id)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: Config.width, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: Config.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: store.openInObsidian) {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open in Obsidian")
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(Color.accentColor)
                        .frame(width: filled.isEmpty ? 0 : geo.size.width * CGFloat(doneCount) / CGFloat(filled.count))
                }
            }
            .frame(height: 4)
            .animation(.easeOut(duration: 0.2), value: doneCount)
        }
    }

    private var title: String {
        guard let date = store.planDate else { return "No note" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private var subtitle: String {
        var parts: [String] = []
        if let date = store.planDate {
            // Compare against store.today (not the clock) so this redraws when the day changes.
            switch Calendar.current.dateComponents([.day], from: store.today, to: date).day {
            case 0: parts.append("Today")
            case 1: parts.append("Tomorrow")
            case -1: parts.append("Yesterday")
            default: break
            }
        }
        parts.append(filled.isEmpty ? "Nothing planned yet" : "\(doneCount) of \(filled.count) done")
        return parts.joined(separator: " · ")
    }
}

struct AddRow: View {
    let store: NoteStore
    let sectionID: Int

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            TextField("Add a task…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit {
                    store.add(text, to: sectionID)
                    text = ""
                    focused = true
                }
        }
        .padding(.vertical, 4)
    }
}

struct TaskRow: View {
    let task: TaskItem
    let store: NoteStore

    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { store.toggle(task.id) } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(task.done ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)

            TextField("Task", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .strikethrough(task.done && !focused)
                .foregroundStyle(task.done ? .secondary : .primary)
                .focused($focused)
                .onSubmit { focused = false }

            Button { store.delete(task.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 0.9 : 0.2)
            .help("Delete")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onAppear { draft = task.text }
        .onChange(of: task.text) { _, text in if !focused { draft = text } }
        .onChange(of: focused) { _, isFocused in
            if !isFocused && draft != task.text { store.setText(task.id, draft) }
        }
    }
}

// MARK: - Window

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { makeFirstResponder(nil) }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = NoteStore()
    private var panel: WidgetPanel!
    private var contentHeight: CGFloat = 240
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        panel = WidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: Config.width, height: contentHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Config.cornerRadius)
        panel.contentView = background

        let hosting = FirstMouseHostingView(rootView: ChecklistView(store: store) { [weak self] height in
            self?.contentHeight = height
            self?.place()
        })
        hosting.sizingOptions = []
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)

        store.isEditing = { [weak self] in self?.panel.firstResponder is NSText }
        store.refresh(force: true)

        place()
        panel.orderFrontRegardless()

        // Commit any in-progress edit when focus moves to another app.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.panel.makeFirstResponder(nil) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }

        let timer = Timer(timeInterval: Config.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        log("started")
    }

    /// Middle of the right edge of the primary screen.
    private func place() {
        guard let screen = NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let height = min(contentHeight, visible.height - 2 * Config.margin)
        let frame = NSRect(
            x: visible.maxX - Config.width - Config.margin,
            y: visible.midY - height / 2,
            width: Config.width, height: height)
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

@main
enum ChecklistWidgetApp {
    static func main() {
        // Documents is synced with iCloud, which can offload files to save space. Background
        // processes aren't allowed to download them back by default (reads fail with
        // "Resource deadlock avoided"), so opt in.
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_ON)

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
