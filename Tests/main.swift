// Tests for Core.swift. Run with ./test.sh (build.sh runs them too and stops if any fail).
// They use a throwaway vault in a temp folder and a fake clock, and never touch real notes.

import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAILED (line \(line)): \(what)")
    }
}

func at(_ text: String) -> Date {
    // "2026-11-07 19:59"
    let n = text.split(whereSeparator: { "- :".contains($0) }).map { Int($0)! }
    return NoteDates.calendar.date(from: DateComponents(year: n[0], month: n[1], day: n[2], hour: n[3], minute: n[4]))!
}

let frontmatter = "---\ntags:\naliases: []\n---\n"
let dailyTemplate = frontmatter + """


## Life:
- [ ] Therapy Log
    
- [ ] GYM
      
- [ ] 
### High brain power work
- [ ] 
## Ai work
- [ ] 
"""
let weeklyTemplate = frontmatter + "\n\n## Life:\n- [ ] \n- [ ] \n## Ai work\n- [ ] \n- [ ] \n"

func tasks(_ text: String, in section: String) -> [String] {
    Markdown.sections(text.components(separatedBy: "\n"))
        .first { $0.title == section }?.tasks.filter { !$0.isBlank }.map { ($0.done ? "x " : "") + $0.text } ?? []
}

// MARK: Dates

check(NoteDates.currentNoteName(.daily, now: at("2026-11-07 00:30")) == "2026-11-07.md", "daily just after midnight is today")
check(NoteDates.currentNoteName(.daily, now: at("2026-11-07 19:59")) == "2026-11-07.md", "daily before 8pm is today")
check(NoteDates.currentNoteName(.daily, now: at("2026-11-07 20:00")) == "2026-11-08.md", "daily from 8pm is tomorrow")
check(NoteDates.currentNoteName(.daily, now: at("2026-12-31 20:00")) == "2027-01-01.md", "daily across new year")
check(NoteDates.currentNoteName(.daily, now: at("2028-02-28 20:00")) == "2028-02-29.md", "daily into a leap day")
check(NoteDates.currentNoteName(.daily, now: at("2026-10-25 20:00")) == "2026-10-26.md", "daily on the day the clocks change")
check(NoteDates.currentNoteName(.weekly, now: at("2026-11-08 23:59")) == "2026-11-02.md", "weekly Sunday night is still this week")
check(NoteDates.currentNoteName(.weekly, now: at("2026-11-09 00:00")) == "2026-11-09.md", "weekly Monday 00:00 is the new week")
check(NoteDates.currentNoteName(.weekly, now: at("2026-11-04 12:00")) == "2026-11-02.md", "weekly midweek")
check(NoteDates.currentNoteName(.weekly, now: at("2027-01-01 12:00")) == "2026-12-28.md", "weekly across new year")
check(NoteDates.date(fromName: "2026-11-07.md") == at("2026-11-07 00:00"), "note name parses to a date")
check(NoteDates.date(fromName: "things to do.md") == nil, "other notes aren't dated")
check(!NoteDates.isNoteName("2026-11-07 copy.md"), "copies aren't dated notes")

// MARK: Markdown

let sample = frontmatter + "## Life:\n- [x] a\n- [ ] \n### Sub\n* [ ] b\n"
let sampleSections = Markdown.sections(sample.components(separatedBy: "\n"))
check(sampleSections.map(\.title) == [nil, "Life", "Sub"], "sections are found, without colons")
check(sampleSections[1].tasks.map(\.text) == ["a", ""], "tasks and empty slots are found")
check(sampleSections[1].tasks[0].done && !sampleSections[1].tasks[1].done, "ticks are read")
check(Markdown.rewrite("  - [ ] old", done: true) == "  - [x] old", "ticking keeps the line")
check(Markdown.rewrite("* [x] old", text: "new") == "* [x] new", "editing keeps the bullet and tick")

// MARK: Template merge

check(Markdown.merge(template: dailyTemplate, into: dailyTemplate) == dailyTemplate, "merging a template into itself changes nothing")
do {
    let note = frontmatter + "## Life:\n- [x] GYM\n- [ ] mine\nremember the receipt\n## Ai work\n- [x] rssm\n## Old section\n- [ ] keep me\nand this text\n## Empty old section\n- [ ] \n"
    let merged = Markdown.merge(template: dailyTemplate, into: note)
    check(tasks(merged, in: "Life") == ["Therapy Log", "x GYM", "mine"], "merge keeps ticks and fills slots")
    check(tasks(merged, in: "High brain power work") == [], "merge adds the template's new section")
    check(tasks(merged, in: "Ai work") == ["x rssm"], "merge keeps tasks in their section")
    check(tasks(merged, in: "Old section") == ["keep me"], "merge keeps sections the template dropped")
    check(merged.contains("remember the receipt"), "merge keeps text written in a section")
    check(merged.contains("and this text"), "merge keeps text in a dropped section")
    check(!merged.contains("Empty old section"), "merge removes dropped sections with nothing in them")
    check(Markdown.merge(template: dailyTemplate, into: merged) == merged, "merging twice gives the same note")
}
do {
    let flat = frontmatter + "\n- [x] done thing\n- [ ] not done\n"
    let merged = Markdown.merge(template: dailyTemplate, into: flat)
    check(tasks(merged, in: "Life") == ["Therapy Log", "GYM", "x done thing", "not done"], "an old flat note's tasks move into the first section")
}

// MARK: Carry-over

do {
    let previous = frontmatter + "## Life:\n- [ ] Therapy Log\n- [x] GYM\n- [ ] call Dad\n- [ ] \n### High brain power work\n- [x] done it\n- [ ] stats\n## Ai work\n- [ ] ALREADY there\n## Gone\n- [ ] orphan\n"
    let next = dailyTemplate.replacingOccurrences(of: "## Ai work\n- [ ] ", with: "## Ai work\n- [x] already  there")
    let result = Markdown.carryOver(from: previous, into: next)
    check(result.carried == ["call Dad", "stats", "orphan"], "only unticked tasks that aren't already there carry: \(result.carried)")
    check(tasks(result.text, in: "Life") == ["Therapy Log", "GYM", "call Dad"], "carried task goes in its section, using an empty slot")
    check(tasks(result.text, in: "High brain power work") == ["stats"], "carried task goes in its subsection")
    check(tasks(result.text, in: "Ai work") == ["x already  there"], "a task ticked on the next list isn't added again")
    check(tasks(result.text, in: "Gone") == ["orphan"], "a section the next note lacks is recreated")
    check(Markdown.hasCarryMarker(result.text), "note is marked once carried into")
    check(Markdown.bodyStart(result.text.components(separatedBy: "\n")) > 0, "frontmatter is still valid")
    check(!result.text.contains("done it"), "ticked tasks stay behind")
}
do {
    let result = Markdown.carryOver(from: "- [ ] a\n- [ ] a\n- [ ] A \n", into: "## Life\n")
    check(result.carried == ["a"], "repeats in the previous note carry once")
    check(tasks(result.text, in: "Life") == ["a"], "flat tasks go in the only section")
    check(Markdown.hasCarryMarker(result.text), "a note with no frontmatter gets one")
    check(!Markdown.hasCarryMarker("- [ ] carryover: done\n"), "the marker only counts in frontmatter")
}
do {
    let previous = frontmatter + "## Life\n- [ ] \n"
    let result = Markdown.carryOver(from: previous, into: dailyTemplate)
    check(result.carried.isEmpty, "empty slots don't carry")
}

// MARK: The whole thing, with a fake clock

@MainActor
final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("checklist-tests-\(UUID().uuidString)")
    let defaults: UserDefaults
    var vault: URL { root.appendingPathComponent("vault") }
    var project: URL { root.appendingPathComponent("project") }
    let suite = "checklist-widget-tests-\(UUID().uuidString)"
    var time = at("2026-11-07 12:00")

    init() {
        defaults = UserDefaults(suiteName: suite)!
        let fm = FileManager.default
        for dir in ["vault/.obsidian", "vault/Templates", "vault/Planning/Worklist", "vault/Planning/Weeklist", "project"] {
            try! fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        write("vault/.obsidian/templates.json", "{\"folder\":\"Templates\"}")
        write("vault/Templates/Daily template.md", dailyTemplate)
        write("vault/Templates/Weekly template.md", weeklyTemplate)
        write("project/worklist-location.txt", "location: \(vault.path)/Planning/Worklist\n")
        write("project/weekly-location.txt", "location: \(vault.path)/Planning/Weeklist\n")
    }

    func write(_ path: String, _ text: String) {
        try! text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    func read(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }
    func store(_ mode: Mode) -> NoteStore {
        let store = NoteStore(mode: mode, projectDirectory: project.path, defaults: defaults)
        store.now = { [unowned self] in self.time }
        return store
    }
    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

MainActor.assumeIsolated {
    // Daily: the 8pm rollover
    do {
        let f = Fixture(); defer { f.cleanUp() }
        let store = f.store(.daily)
        store.refresh(force: true)
        check(store.errorMessage == nil, "no error: \(store.errorMessage ?? "")")
        check(store.noteURL?.lastPathComponent == "2026-11-07.md", "today's note is created")
        let today = "vault/Planning/Worklist/2026-11-07.md"
        check(f.read(today).hasPrefix(frontmatter), "it comes from the template")
        check(!Markdown.hasCarryMarker(f.read(today)), "the very first note has nothing to carry from")

        let life = store.sections.first { $0.title == "Life" }!.id
        let ai = store.sections.first { $0.title == "Ai work" }!.id
        store.add("left over", to: life)
        store.add("finished", to: ai)
        store.add("rssm maths", to: ai)
        store.toggle(store.tasks.first { $0.text == "finished" }!.id)
        store.toggle(store.tasks.first { $0.text == "GYM" }!.id)
        let todayBefore = f.read(today)

        f.time = at("2026-11-07 19:59")
        store.refresh()
        check(store.noteURL?.lastPathComponent == "2026-11-07.md", "nothing changes before 8pm")

        f.time = at("2026-11-07 20:00")
        store.refresh()
        let tomorrow = "vault/Planning/Worklist/2026-11-08.md"
        check(store.noteURL?.lastPathComponent == "2026-11-08.md", "tomorrow's note appears at 8pm")
        let created = f.read(tomorrow)
        check(tasks(created, in: "Life") == ["Therapy Log", "GYM", "left over"], "leftovers carry, template tasks aren't doubled, GYM is fresh: \(tasks(created, in: "Life"))")
        check(tasks(created, in: "Ai work") == ["rssm maths"], "unticked carries, ticked doesn't")
        check(store.tasks.contains { $0.text == "left over" }, "the widget shows carried tasks straight away")
        check(f.read(today) == todayBefore, "the old note isn't changed")

        // Deleting a carried task must stick, across refreshes and restarts.
        store.delete(store.tasks.first { $0.text == "left over" }!.id)
        f.time = at("2026-11-07 20:01")
        store.refresh()
        let restarted = f.store(.daily)
        restarted.refresh(force: true)
        restarted.refresh()
        check(tasks(f.read(tomorrow), in: "Life") == ["Therapy Log", "GYM"], "a deleted carried task stays deleted")

        // Next night it keeps rolling, only once.
        f.time = at("2026-11-08 20:00")
        restarted.refresh()
        restarted.refresh()
        check(tasks(f.read("vault/Planning/Worklist/2026-11-09.md"), in: "Ai work") == ["rssm maths"], "it keeps carrying, once")
    }

    // Daily: Mac off for days, and a note made by hand
    do {
        let f = Fixture(); defer { f.cleanUp() }
        f.write("vault/Planning/Worklist/2026-11-01.md", dailyTemplate + "\n- [ ] ancient")
        f.write("vault/Planning/Worklist/2026-11-03.md", dailyTemplate.replacingOccurrences(of: "## Ai work\n- [ ] ", with: "## Ai work\n- [ ] from tuesday"))
        f.write("vault/Planning/Worklist/things to get done.md", "- [ ] not a dated note")
        let store = f.store(.daily)
        f.time = at("2026-11-07 09:00")
        store.refresh()
        let note = f.read("vault/Planning/Worklist/2026-11-07.md")
        check(tasks(note, in: "Ai work") == ["from tuesday"], "after days off it carries from the newest note there is")
        check(!note.contains("not a dated note"), "other notes in the folder are ignored")

        f.write("vault/Planning/Worklist/2026-11-08.md", frontmatter + "## Life:\n- [ ] planned by hand\n## Ai work\n- [ ] FROM TUESDAY\n")
        store.refresh()
        let byHand = f.read("vault/Planning/Worklist/2026-11-08.md")
        check(store.noteURL?.lastPathComponent == "2026-11-08.md", "a newer note made by hand takes over")
        check(tasks(byHand, in: "Life").contains("planned by hand"), "a note made by hand keeps its tasks")
        check(tasks(byHand, in: "Ai work") == ["FROM TUESDAY"], "and doesn't get a duplicate")
    }

    // Weekly: the Sunday-night reset
    do {
        let f = Fixture(); defer { f.cleanUp() }
        let store = f.store(.weekly)
        f.time = at("2026-11-04 12:00")
        store.refresh(force: true)
        check(store.noteURL?.lastPathComponent == "2026-11-02.md", "this week's note is named after Monday")
        let ai = store.sections.first { $0.title == "Ai work" }!.id
        store.add("dreamer prep", to: ai)
        store.add("week job done", to: ai)
        store.toggle(store.tasks.first { $0.text == "week job done" }!.id)

        f.time = at("2026-11-08 23:59")
        store.refresh()
        check(store.noteURL?.lastPathComponent == "2026-11-02.md", "Sunday night is still this week")
        f.time = at("2026-11-09 00:00")
        store.refresh()
        check(store.noteURL?.lastPathComponent == "2026-11-09.md", "Monday 00:00 starts the new week")
        check(tasks(f.read("vault/Planning/Weeklist/2026-11-09.md"), in: "Ai work") == ["dreamer prep"], "weekly leftovers carry")
    }

    // Daily and weekly stay separate
    do {
        let f = Fixture(); defer { f.cleanUp() }
        let daily = f.store(.daily), weekly = f.store(.weekly)
        daily.refresh(force: true); weekly.refresh(force: true)
        check(daily.noteURL?.deletingLastPathComponent().lastPathComponent == "Worklist", "daily uses its folder")
        check(weekly.noteURL?.deletingLastPathComponent().lastPathComponent == "Weeklist", "weekly uses its folder")
        check(f.read("vault/Planning/Weeklist/2026-11-02.md").contains("Therapy Log") == false, "weekly uses its own template")
    }

    // Template changes
    do {
        let f = Fixture(); defer { f.cleanUp() }
        let store = f.store(.daily)
        f.write("vault/Planning/Worklist/2026-11-06.md", dailyTemplate)
        let oldNote = f.read("vault/Planning/Worklist/2026-11-06.md")
        store.refresh(force: true)
        store.add("mine", to: store.sections.first { $0.title == "Ai work" }!.id)
        let edited = dailyTemplate + "\n## Brand new\n- [ ] read a paper\n"
        f.write("vault/Templates/Daily template.md", edited)
        store.refresh()
        let note = f.read("vault/Planning/Worklist/2026-11-07.md")
        check(tasks(note, in: "Brand new") == ["read a paper"], "the current note follows the template")
        check(tasks(note, in: "Ai work") == ["mine"], "and keeps its tasks")
        check(Markdown.hasCarryMarker(note), "and keeps its carry-over mark")
        check(f.read("vault/Planning/Worklist/2026-11-06.md") == oldNote, "old notes are left alone")

        // Renaming the template, or losing Obsidian's settings, doesn't lose it.
        try! FileManager.default.moveItem(at: f.root.appendingPathComponent("vault/Templates/Daily template.md"),
                                          to: f.root.appendingPathComponent("vault/Templates/My daily plan.md"))
        try! FileManager.default.removeItem(at: f.root.appendingPathComponent("vault/.obsidian/templates.json"))
        f.time = at("2026-11-07 20:00")
        store.refresh()
        check(tasks(f.read("vault/Planning/Worklist/2026-11-08.md"), in: "Brand new") == ["read a paper"], "the template is still found after a rename")
    }

    // Things moving or breaking
    do {
        let f = Fixture(); defer { f.cleanUp() }
        let store = f.store(.daily)
        store.refresh(force: true)
        let fm = FileManager.default

        // The Worklist folder moves: follow it and correct the location file.
        try! fm.moveItem(at: f.root.appendingPathComponent("vault/Planning"), to: f.root.appendingPathComponent("vault/Renamed"))
        store.refresh()
        check(store.noteURL?.path.contains("vault/Renamed/Worklist") == true, "a moved folder is followed")
        check(f.read("project/worklist-location.txt").contains("Renamed"), "the location file is corrected")

        // The project folder moves.
        try! fm.moveItem(at: f.project, to: f.root.appendingPathComponent("moved-project"))
        store.refresh()
        check(store.errorMessage == nil, "a moved project folder is followed")

        // The location file vanishes: keep using the last good folder.
        try! fm.removeItem(at: f.root.appendingPathComponent("moved-project/worklist-location.txt"))
        store.refresh()
        check(store.noteURL != nil && store.errorMessage == nil, "a missing location file doesn't blank the widget")

        // A typo in the location file is shown, not silently overwritten.
        f.write("moved-project/worklist-location.txt", "location: /nowhere/at/all\n")
        store.refresh()
        check(store.errorMessage?.contains("/nowhere/at/all") == true, "a wrong path shows an error")
        check(f.read("moved-project/worklist-location.txt").contains("/nowhere/at/all"), "and the file isn't overwritten")
    }

    // A forgotten cursor doesn't stop the rollover, and doesn't switch notes while typing.
    do {
        let f = Fixture(); defer { f.cleanUp() }
        let store = f.store(.daily)
        store.refresh(force: true)
        var typing = true
        var askedToStop = false
        store.isEditing = { typing }
        store.endEditing = { askedToStop = true; typing = false }
        f.time = at("2026-11-07 19:00")
        store.refresh()
        check(!askedToStop, "typing isn't interrupted before the rollover")
        f.time = at("2026-11-07 20:00")
        store.refresh()
        check(askedToStop && store.noteURL?.lastPathComponent == "2026-11-07.md", "at the rollover it saves first, without switching yet")
        store.refresh()
        check(store.noteURL?.lastPathComponent == "2026-11-08.md", "then it switches")
    }
}

print(failures == 0 ? "all \(checks) checks passed" : "\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
