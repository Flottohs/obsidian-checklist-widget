// The checklist widget's logic: dates, markdown, template merging, carry-over and files.
// There is no window code here, so test.sh can exercise all of it. See README.md.

import AppKit
import Observation

// MARK: - Config

/// Which checklist a widget shows. Each runs as its own process (see build.sh).
enum Mode {
    case daily, weekly

    var locationFileName: String { self == .daily ? "worklist-location.txt" : "weekly-location.txt" }
    var templateName: String { self == .daily ? "Daily template.md" : "Weekly template.md" }
    var templateKeyword: String { self == .daily ? "daily" : "weekly" }
    /// Both modes share one defaults domain (same binary), so weekly keys get a prefix.
    var defaultsPrefix: String { self == .daily ? "" : "weekly." }
    /// Position counted from the right edge of the screen.
    var slot: Int { self == .daily ? 0 : 1 }
}

enum Config {
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
    static let gap: CGFloat = 16
    static let cornerRadius: CGFloat = 18
    static let pollInterval: TimeInterval = 1.5
    static let rolloverHour = 20  // 8pm: tomorrow's daily note gets created
    static let maxLogBytes = 1_000_000
}

func log(_ message: String) {
    print("[\(Date())] \(message)")
    fflush(stdout)
}

/// launchd sends stdout to a log file that nothing else ever trims, so start over if it gets big.
func trimLogIfHuge() {
    var info = stat()
    guard fstat(STDOUT_FILENO, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) > Config.maxLogBytes else { return }
    if ftruncate(STDOUT_FILENO, 0) == 0 { log("log trimmed") }
}

// MARK: - Dates

/// Note names are YYYY-MM-DD.md: the day a daily note is for, or the Monday of a weekly note's week.
enum NoteDates {
    /// Always Gregorian with Monday first, whatever the Mac's region settings are.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = 2
        return calendar
    }

    static func name(of date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.md", parts.year!, parts.month!, parts.day!)
    }

    static func isNoteName(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}-\d{2}\.md$"#, options: .regularExpression) != nil
    }

    static func date(fromName name: String) -> Date? {
        guard isNoteName(name) else { return nil }
        let parts = name.dropLast(3).split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Monday 00:00 of the week containing the date.
    static func weekStart(_ date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)!.start
    }

    /// The note that should exist by now. Daily: tomorrow's from the rollover hour on,
    /// otherwise today's. Weekly: this week's.
    static func currentNoteName(_ mode: Mode, now: Date) -> String {
        switch mode {
        case .daily:
            let isEvening = calendar.component(.hour, from: now) >= Config.rolloverHour
            return name(of: isEvening ? calendar.date(byAdding: .day, value: 1, to: now)! : now)
        case .weekly:
            return name(of: weekStart(now))
        }
    }
}

// MARK: - Location

/// A Worklist folder and the Obsidian vault it sits in.
struct WorklistLocation {
    let folder: URL
    let vault: URL?
    let mode: Mode

    init(folder: URL, mode: Mode) {
        self.folder = folder
        self.mode = mode
        vault = Self.findVault(containing: folder)
    }

    enum Problem: LocalizedError {
        case unreadable(path: String, reason: String)
        case noLocationLine(file: String)
        case folderMissing(path: String, file: String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let path, let reason): return "Can't read \(path)\n\(reason)"
            case .noLocationLine(let file): return "Add a line like \"location: ~/path/to/folder\" to \(file)"
            case .folderMissing(let path, let file): return "Folder not found:\n\(path)\nUpdate \(file)"
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
        else { throw Problem.noLocationLine(file: file.lastPathComponent) }
        var path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") { path = String(path.dropFirst().dropLast()) }
        guard !path.isEmpty else { throw Problem.noLocationLine(file: file.lastPathComponent) }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// Rewrites the "location:" line, keeping any other lines in the file.
    static func setConfiguredFolder(_ folder: URL, in file: URL) throws {
        let newLine = "\(prefix) \((folder.path as NSString).abbreviatingWithTildeInPath)"
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

    /// The vault's templates folder: the one set in Obsidian, or else any top-level folder
    /// with "template" in its name.
    private var templatesFolder: URL? {
        guard let vault else { return nil }
        if let data = try? Data(contentsOf: vault.appendingPathComponent(".obsidian/templates.json")),
           let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let folder = settings["folder"] as? String {
            return vault.appendingPathComponent(folder)
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: vault.path)) ?? []
        return names.sorted().first { $0.lowercased().contains("template") }.map { vault.appendingPathComponent($0) }
    }

    /// "Daily template.md" (or "Weekly template.md") if present, otherwise any note in the
    /// templates folder with "daily" (or "weekly") in its name, so renaming it doesn't break things.
    var template: URL? {
        guard let folder = templatesFolder,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return nil }
        let notes = names.filter { $0.lowercased().hasSuffix(".md") }.sorted()
        let name = notes.first { $0.lowercased() == mode.templateName.lowercased() }
            ?? notes.first { $0.lowercased().contains(mode.templateKeyword) }
        return name.map { folder.appendingPathComponent($0) }
    }
}

/// Works out the Worklist folder on each refresh, and recovers when things move:
/// - the location file is followed by bookmark if its folder (e.g. Developer) is moved,
/// - the Worklist folder is followed by bookmark if it's moved, and the file is corrected,
/// - if the file can't be read at all, the last folder that worked keeps being used.
@MainActor
final class LocationResolver {
    private let mode: Mode
    private let defaults: UserDefaults
    private var locationFile: URL
    private var lastGood: WorklistLocation?
    private var lastWarning: String?
    private var fileBookmarkKey: String { mode.defaultsPrefix + "locationFileBookmark" }
    private var folderBookmarkKey: String { mode.defaultsPrefix + "worklistFolderBookmark" }
    private var folderPathKey: String { mode.defaultsPrefix + "worklistFolderPath" }

    init(mode: Mode, projectDirectory: String, defaults: UserDefaults) {
        self.mode = mode
        self.defaults = defaults
        locationFile = URL(fileURLWithPath: projectDirectory).appendingPathComponent(mode.locationFileName)
    }

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
        throw WorklistLocation.Problem.folderMissing(path: configured.path, file: locationFile.lastPathComponent)
    }

    private func remember(_ folder: URL, healthy: Bool = true) -> WorklistLocation {
        if lastGood?.folder != folder {
            lastGood = WorklistLocation(folder: folder, mode: mode)
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

    /// Adds a task to a section: fills its first empty slot after its last filled task, otherwise
    /// adds a line after its last task (or straight under its heading).
    static func insert(_ text: String, into section: Section, lines: inout [String]) {
        let lastFilled = section.tasks.last(where: { !$0.isBlank })?.id ?? -1
        if let blank = section.tasks.first(where: { $0.isBlank && $0.id > lastFilled }) {
            lines[blank.lineIndex] = rewrite(lines[blank.lineIndex], done: false, text: text)
        } else if let last = section.tasks.last {
            let indent = String(lines[last.lineIndex].prefix { $0 == " " || $0 == "\t" })
            lines.insert(indent + "- [ ] " + text, at: last.lineIndex + 1)
        } else if let heading = section.headingLine {
            lines.insert("- [ ] " + text, at: heading + 1)
        } else {
            appendLine("- [ ] " + text, to: &lines)
        }
    }

    /// Adds a line at the end of the note, before its final newline if it has one.
    private static func appendLine(_ line: String, to lines: inout [String]) {
        if lines.last == "" { lines.insert(line, at: lines.count - 1) } else { lines.append(line) }
    }

    // MARK: Carry-over

    /// Written into a note's frontmatter once it has received the previous note's unfinished
    /// tasks, so it only ever happens once. A task you delete afterwards stays deleted.
    /// Removing this line makes the widget carry over into that note again.
    static let carryMarker = "carryover: done"

    static func hasCarryMarker(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        return lines[..<bodyStart(lines)].contains { $0.trimmingCharacters(in: .whitespaces) == carryMarker }
    }

    /// Same task if it only differs in capitals or spacing.
    private static func taskKey(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Adds the previous note's unticked tasks to this note, in the section with the same name,
    /// skipping any already in this note (ticked or not, in any section), and marks it as done.
    static func carryOver(from previous: String, into note: String) -> (text: String, carried: [String]) {
        let previousLines = previous.components(separatedBy: "\n")
        var lines = note.components(separatedBy: "\n")
        var existing = Set(sections(lines).flatMap(\.tasks).map { taskKey($0.text) })
        var carried: [String] = []

        for section in sections(previousLines) {
            for task in section.tasks where !task.done && !task.isBlank {
                guard existing.insert(taskKey(task.text)).inserted else { continue }
                let current = sections(lines)
                if let target = target(for: section.title, in: current) {
                    insert(task.text, into: target, lines: &lines)
                } else {
                    // This note has no section with that name: recreate it at the end.
                    appendLine(previousLines[section.headingLine!], to: &lines)
                    appendLine("- [ ] " + task.text, to: &lines)
                }
                carried.append(task.text)
            }
        }

        let frontmatterEnd = bodyStart(lines)
        if frontmatterEnd > 0 {
            lines.insert(carryMarker, at: frontmatterEnd - 1)
        } else {
            lines.insert(contentsOf: ["---", carryMarker, "---"], at: 0)
        }
        return (lines.joined(separator: "\n"), carried)
    }

    /// The section a carried task belongs in. Tasks from before any heading (old flat notes)
    /// go in the first section that has tasks, or else the first section there is.
    private static func target(for title: String?, in sections: [Section]) -> Section? {
        if let title { return sections.first { $0.title?.lowercased() == title.lowercased() } }
        return sections.first { !$0.tasks.isEmpty } ?? sections.first { $0.title != nil } ?? sections.first
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

    private static func isBlankLine(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Anything in a section you wrote that isn't a task or a blank line.
    private static func looseText(_ lines: [String]) -> [String] {
        lines.filter { !isBlankLine($0) && task(in: $0) == nil }
    }

    /// Lays the note out like the template: the template's sections in its order and format,
    /// with the note's tasks kept in their matching sections (ticks preserved, filling the
    /// template's empty slots first) and any text you wrote kept at the end of its section.
    /// Sections the template doesn't have are kept at the end if they have anything in them,
    /// and the note's own frontmatter is kept. Nothing you wrote is dropped, except that a
    /// task repeated word for word becomes one.
    static func merge(template: String, into note: String) -> String {
        let templateLines = template.components(separatedBy: "\n")
        let noteLines = note.components(separatedBy: "\n")
        let templateChunks = chunks(templateLines)
        let noteChunks = chunks(noteLines)

        // The note's filled tasks and loose text, grouped by section.
        var pools: [String: [Task]] = [:]
        var texts: [String: [String]] = [:]
        for chunk in noteChunks {
            pools[chunk.key, default: []] += chunk.lines.compactMap(task(in:)).filter { !$0.text.isEmpty }
            texts[chunk.key, default: []] += looseText(chunk.lines)
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
            // Text you wrote in this section, unless the template already says it.
            let templateText = Set(looseText(chunk.lines))
            let kept = (texts[chunk.key] ?? []).filter { !templateText.contains($0) }
            if !kept.isEmpty {
                let at = (out.lastIndex { !isBlankLine($0) }).map { $0 + 1 } ?? 0
                out.insert(contentsOf: kept, at: at)
            }
            if let heading = chunk.headingLine { body.append(heading) }
            body += out
        }

        // Keep anything in sections the template no longer has.
        for chunk in noteChunks where !templateKeys.contains(chunk.key) {
            let filledTask = chunk.lines.contains { task(in: $0).map { !$0.text.isEmpty } ?? false }
            guard filledTask || !looseText(chunk.lines).isEmpty else { continue }
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
    /// Start of the current day; observed so the Today/Tomorrow label redraws at midnight.
    private(set) var today: Date
    var tasks: [TaskItem] { sections.flatMap(\.tasks) }

    let mode: Mode
    /// The clock; tests replace it to simulate 8pm and Mondays.
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored var isEditing: () -> Bool = { false }
    /// Takes the cursor out of whichever field has it, which saves what was typed.
    @ObservationIgnored var endEditing: () -> Void = {}
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let resolver: LocationResolver
    @ObservationIgnored private var loadedModified: Date?
    @ObservationIgnored private var location: WorklistLocation?
    @ObservationIgnored private var templateWarning: String?
    @ObservationIgnored private var carryWarning: String?
    /// Template text last applied to each recent note, so a note is only re-shaped when the template changes.
    private var appliedTemplatesKey: String { mode.defaultsPrefix + "appliedTemplates" }

    init(mode: Mode, projectDirectory: String, defaults: UserDefaults = .standard) {
        self.mode = mode
        self.defaults = defaults
        resolver = LocationResolver(mode: mode, projectDirectory: projectDirectory, defaults: defaults)
        today = NoteDates.calendar.startOfDay(for: Date())
    }

    /// The date in the note's name.
    var planDate: Date? {
        noteURL.flatMap { NoteDates.date(fromName: $0.lastPathComponent) }
    }

    // MARK: Loading

    func refresh(force: Bool = false) {
        let now = now()
        let startOfToday = NoteDates.calendar.startOfDay(for: now)
        if startOfToday != today {
            today = startOfToday
            trimLogIfHuge()
        }
        if isEditing() {
            // Never switch notes under someone typing. But a cursor left in a field shouldn't
            // stop the note rolling over, so save and let the next refresh do the switch.
            if let shown = noteURL?.lastPathComponent, shown < NoteDates.currentNoteName(mode, now: now) { endEditing() }
            if !force { return }
        }
        do {
            let location = try resolver.resolve()
            self.location = location
            let template = readTemplate(location)
            let url = try resolveNote(in: location, template: template, now: now)
            // Only the newest note is ever changed; older ones are left as history.
            if let template { try syncWithTemplate(template, note: url) }
            carryOver(into: url, location: location)
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
        let text = location.template
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let warning = text == nil ? "no \(mode.templateKeyword) template found - using a plain checklist" : nil
        if warning != templateWarning {
            log(warning ?? "using template \(location.template?.lastPathComponent ?? "")")
            templateWarning = warning
        }
        return text
    }

    private func datedNotes(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter(NoteDates.isNoteName).sorted()
    }

    /// Newest dated note in the folder; creates the current one from the template if nothing is that new.
    private func resolveNote(in location: WorklistLocation, template: String?, now: Date) throws -> URL {
        let fm = FileManager.default
        let currentName = NoteDates.currentNoteName(mode, now: now)
        if let newest = try datedNotes(in: location.folder).last, newest >= currentName {
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

    /// Re-shapes the note to the template when the template has changed since.
    private func syncWithTemplate(_ template: String, note url: URL) throws {
        let name = url.lastPathComponent
        let applied = defaults.dictionary(forKey: appliedTemplatesKey) as? [String: String] ?? [:]
        guard applied[name] != template else { return }
        let original = try String(contentsOf: url, encoding: .utf8)
        let merged = Markdown.merge(template: template, into: original)
        if merged != original {
            try merged.write(to: url, atomically: true, encoding: .utf8)
            log("updated \(name) to match the template")
        }
        recordApplied(template, to: name)
    }

    private func recordApplied(_ template: String, to name: String) {
        var applied = defaults.dictionary(forKey: appliedTemplatesKey) as? [String: String] ?? [:]
        applied[name] = template
        // Only recent notes matter.
        for key in applied.keys.sorted().dropLast(14) { applied.removeValue(forKey: key) }
        defaults.set(applied, forKey: appliedTemplatesKey)
    }

    /// Brings unfinished tasks forward from the note before this one, once per note. If a file
    /// can't be read right now this just tries again on the next refresh.
    private func carryOver(into url: URL, location: WorklistLocation) {
        let name = url.lastPathComponent
        do {
            let note = try String(contentsOf: url, encoding: .utf8)
            if Markdown.hasCarryMarker(note) { return }
            guard let previous = try datedNotes(in: location.folder).last(where: { $0 < name }) else { return }
            let previousText = try String(contentsOf: location.folder.appendingPathComponent(previous), encoding: .utf8)
            let result = Markdown.carryOver(from: previousText, into: note)
            try result.text.write(to: url, atomically: true, encoding: .utf8)
            log("carried \(result.carried.count) unfinished from \(previous) into \(name)")
            carryWarning = nil
        } catch {
            let warning = "couldn't carry over into \(name): \(error.localizedDescription)"
            if warning != carryWarning { log(warning); carryWarning = warning }
        }
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

    func add(_ text: String, to sectionID: Int) {
        let clean = Self.sanitize(text)
        guard !clean.isEmpty else { return }
        mutate { lines, sections in
            guard let section = sections.first(where: { $0.id == sectionID }) else { return }
            Markdown.insert(clean, into: section, lines: &lines)
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
