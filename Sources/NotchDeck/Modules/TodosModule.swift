import SwiftUI
import AppKit
import Observation

// MARK: - Model

struct TodoTask: Identifiable, Equatable {
    let id: String          // stable hash of section + text (+ occurrence index for duplicates)
    let text: String
    let section: String?
    let done: Bool          // effective state (file state XOR local toggle)
}

struct ParsedTodo: Equatable {
    let text: String
    let section: String?
    let done: Bool
}

// MARK: - Parser (tolerant; never throws)

enum TodoParser {
    static let maxTasks = 200
    static let maxBytes = 1_000_000

    private static let taskRe = try? NSRegularExpression(pattern: #"^(?:[-*+]|\d{1,4}[.)])\s+\[\s*([xX ✓✔]?)\s*\]\s*(.*)$"#)
    private static let bulletRe = try? NSRegularExpression(pattern: #"^(?:[-*+]|\d{1,4}[.)])\s+(.+)$"#)
    private static let headingRe = try? NSRegularExpression(pattern: #"^#{1,6}\s+(.+?)\s*#*\s*$"#)

    static func parse(data: Data, isJSON: Bool) -> [ParsedTodo] {
        let slice = data.count > maxBytes ? data.prefix(maxBytes) : data
        if isJSON, let r = parseJSON(Data(slice)) { return r }
        let text = String(decoding: slice, as: UTF8.self)
        return parseMarkdown(text)
    }

    static func parseMarkdown(_ text: String) -> [ParsedTodo] {
        var out: [ParsedTodo] = []
        var section: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            if out.count >= maxTasks { break }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let m = match(headingRe, line), let h = group(m, 1, in: line) {
                let t = clean(h)
                section = t.isEmpty ? nil : t
                continue
            }
            if let m = match(taskRe, line), let body = group(m, 2, in: line) {
                let mark = group(m, 1, in: line) ?? ""
                let t = clean(body)
                if !t.isEmpty { out.append(ParsedTodo(text: t, section: section, done: !mark.trimmingCharacters(in: .whitespaces).isEmpty)) }
                continue
            }
            if let m = match(bulletRe, line), let body = group(m, 1, in: line) {
                let t = clean(body)
                if !t.isEmpty { out.append(ParsedTodo(text: t, section: section, done: false)) }
            }
            // anything else is prose: ignored
        }
        return out
    }

    static func parseJSON(_ data: Data) -> [ParsedTodo]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var arr: [Any]?
        if let a = obj as? [Any] { arr = a }
        else if let d = obj as? [String: Any] {
            for k in ["tasks", "todos", "items", "list"] { if let a = d[k] as? [Any] { arr = a; break } }
        }
        guard let items = arr else { return nil }
        var out: [ParsedTodo] = []
        for item in items {
            if out.count >= maxTasks { break }
            if let s = item as? String {
                let t = clean(s)
                if !t.isEmpty { out.append(ParsedTodo(text: t, section: nil, done: false)) }
            } else if let d = item as? [String: Any] {
                var title: String?
                for k in ["title", "text", "task", "name", "content"] { if let s = d[k] as? String { title = s; break } }
                guard let title else { continue }
                let t = clean(title)
                if t.isEmpty { continue }
                var done = false
                for k in ["done", "completed", "complete", "checked"] {
                    if let b = d[k] as? Bool { done = b; break }
                    if let n = d[k] as? NSNumber { done = n.boolValue; break }
                }
                if let st = d["status"] as? String, ["done", "completed", "complete", "closed"].contains(st.lowercased()) { done = true }
                var sec: String?
                for k in ["section", "category", "group", "project", "list"] { if let s = d[k] as? String, !s.isEmpty { sec = clean(s); break } }
                out.append(ParsedTodo(text: t, section: sec, done: done))
            }
        }
        return out
    }

    // MARK: helpers

    private static func match(_ re: NSRegularExpression?, _ s: String) -> NSTextCheckingResult? {
        re?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String? {
        guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: s) else { return nil }
        return String(s[r])
    }

    private static let emphasis: [NSRegularExpression] = [
        #"\[([^\]]*)\]\([^)]*\)"#,       // links -> text
        #"\*\*(.+?)\*\*"#, #"__(.+?)__"#, #"~~(.+?)~~"#,
        #"\*(.+?)\*"#, #"(?<![A-Za-z0-9])_(.+?)_(?![A-Za-z0-9])"#, #"`([^`]*)`"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func clean(_ s: String) -> String {
        var t = s
        for re in emphasis {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1")
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 300 { t = String(t.prefix(300)) + "..." }
        return t
    }
}

// MARK: - Module

@MainActor
@Observable
final class TodosModule: NotchModule {
    enum Status: Equatable { case loading, ready, missing, failure(String) }

    let id = "todos"
    let title = "Todos"
    let icon = "checklist"
    let priority = 40

    private(set) var tasks: [TodoTask] = []
    private(set) var status: Status = .loading

    /// User-configurable source file (supports ~).
    var filePath: String {
        didSet {
            guard filePath != oldValue else { return }
            UserDefaults.standard.set(filePath, forKey: Self.pathKey)
            lastOpenCount = nil
            if running { startWatching(); reload() }
        }
    }

    var badgeCount: Int { tasks.lazy.filter { !$0.done }.count }

    static let defaultPath = "~/todos.md"
    var resolvedPath: String { (filePath.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }

    @ObservationIgnored private var running = false
    @ObservationIgnored private var parsed: [ParsedTodo] = []
    @ObservationIgnored private var toggled: Set<String>
    @ObservationIgnored private weak var state: NotchState?
    @ObservationIgnored private var sources: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var debounce: DispatchWorkItem?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastOpenCount: Int?
    @ObservationIgnored private let queue = DispatchQueue(label: "notchdeck.todos.read", qos: .utility)

    private static let pathKey = "todos.filePath"
    private static let toggledKey = "todos.toggled"
    private static let maxToggled = 1000

    init() {
        let ud = UserDefaults.standard
        filePath = ud.string(forKey: Self.pathKey) ?? Self.defaultPath
        toggled = Set(ud.stringArray(forKey: Self.toggledKey) ?? [])
    }

    // MARK: Lifecycle

    func start(state: NotchState) {
        self.state = state
        running = true
        lastOpenCount = nil
        startWatching()
        reload()
        scheduleDailyRefresh()
    }

    /// Re-read the list once a day (just after midnight) on top of the file watcher, so day-based
    /// sections stay current even if the file didn't change. One one-shot work item at a time.
    @ObservationIgnored private var dailyWork: DispatchWorkItem?
    private func scheduleDailyRefresh() {
        dailyWork?.cancel()
        let cal = Calendar.current
        let next = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!.addingTimeInterval(60)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.reload()
                self.scheduleDailyRefresh()
            }
        }
        dailyWork = work
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + next.timeIntervalSinceNow, execute: work)
    }

    func stop() {
        dailyWork?.cancel(); dailyWork = nil
        running = false
        stopWatching()
        debounce?.cancel(); debounce = nil
        generation += 1
    }

    func onEvent(_ event: NotchEvent) {
        // Retry once per open if nothing is being watched yet (e.g. parent folder was missing).
        if event == .opened, running, sources.isEmpty { startWatching(); reload() }
    }

    func expandedView() -> AnyView { AnyView(TodosView(module: self)) }

    // MARK: Watching (event-driven; no polling)

    private func startWatching() {
        stopWatching()
        let path = resolvedPath
        let dir = (path as NSString).deletingLastPathComponent
        for p in [path, dir.isEmpty ? "/" : dir] {
            let fd = open(p, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
            src.setEventHandler { [weak self, weak src] in
                let flags = src?.data ?? []
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scheduleReload()
                    if flags.contains(.delete) || flags.contains(.rename) {
                        // File replaced (atomic save): re-arm on the new inode.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                            MainActor.assumeIsolated { if self?.running == true { self?.startWatching() } }
                        }
                    }
                }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources.append(src)
        }
    }

    private func stopWatching() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }

    private func scheduleReload() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Loading

    func reload() {
        generation += 1
        let gen = generation
        let path = resolvedPath
        let isJSON = path.lowercased().hasSuffix(".json")
        queue.async { [weak self] in
            var result: Result<[ParsedTodo], Error>?
            var missing = false
            if !FileManager.default.fileExists(atPath: path) {
                missing = true
            } else if let fh = FileHandle(forReadingAtPath: path) {
                defer { try? fh.close() }
                let data = (try? fh.read(upToCount: TodoParser.maxBytes)) ?? Data()
                result = .success(TodoParser.parse(data: data, isJSON: isJSON))
            } else {
                result = .failure(NSError(domain: "todos", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "Can't read the file"]))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(result: result, missing: missing, generation: gen) }
            }
        }
    }

    private func apply(result: Result<[ParsedTodo], Error>?, missing: Bool, generation gen: Int) {
        guard gen == generation, running else { return }
        if missing { status = .missing; parsed = []; tasks = []; noteOpenCount(0, announce: false); return }
        switch result {
        case .success(let p):
            parsed = p
            status = .ready
            rebuild(announce: true)
        case .failure(let e):
            status = .failure(e.localizedDescription)   // keep last good list
        case .none:
            break
        }
    }

    private func rebuild(announce: Bool) {
        var seen: [String: Int] = [:]
        var built: [TodoTask] = []
        for p in parsed {
            let base = Self.key(section: p.section, text: p.text)
            let n = seen[base, default: 0]
            seen[base] = n + 1
            let key = n == 0 ? base : base + "#\(n)"
            built.append(TodoTask(id: key, text: p.text, section: p.section, done: p.done != toggled.contains(key)))
        }
        tasks = built
        noteOpenCount(built.filter { !$0.done }.count, announce: announce)
    }

    private func noteOpenCount(_ open: Int, announce: Bool) {
        if let last = lastOpenCount, last != open, announce {
            let label = open == 1 ? "1 open task" : "\(open) open tasks"
            state?.showTransient(Transient(icon: "checklist", label: label, value: nil, tint: .green), duration: 4)
        }
        lastOpenCount = open
    }

    // MARK: Local done state (never writes to the user's file)

    func toggle(_ task: TodoTask) {
        if toggled.contains(task.id) { toggled.remove(task.id) } else { toggled.insert(task.id) }
        if toggled.count > Self.maxToggled { toggled = Set(toggled.shuffled().prefix(Self.maxToggled)) }
        UserDefaults.standard.set(Array(toggled), forKey: Self.toggledKey)
        withAnimation(.smooth(duration: 0.2)) { rebuild(announce: false) }
    }

    /// Stable (non-randomized) FNV-1a hash of section + text.
    private static func key(section: String?, text: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in ((section ?? "") + "\u{1F}" + text).utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    // MARK: Settings helpers

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose your todo file (Markdown or JSON)"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            filePath = url.path
        }
    }
}

// MARK: - View

struct TodosView: View {
    let module: TodosModule
    @StateObject private var expandBox = Local(false)
    private var showAllDone: Bool { get { expandBox.value } nonmutating set { expandBox.value = newValue } }

    private var open: [TodoTask] { module.tasks.filter { !$0.done } }
    private var done: [TodoTask] { module.tasks.filter { $0.done } }

    var body: some View {
        switch module.status {
        case .missing: emptyState(failure: nil)
        case .failure(let m) where module.tasks.isEmpty: emptyState(failure: m)
        case .loading where module.tasks.isEmpty: message("checklist", "Loading...")
        default: list
        }
    }

    private func emptyState(failure: String?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: failure == nil ? "checklist" : "exclamationmark.triangle")
                .font(.system(size: 26)).foregroundStyle(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 4) {
                Text(failure == nil ? "No todo file yet" : "Can't read todo file")
                    .font(.system(size: 13, weight: .semibold))
                Text(module.resolvedPath).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55)).lineLimit(1).truncationMode(.middle)
                Text(failure ?? "Create this file or pick another one in Settings.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func message(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Open tasks grouped by section, preserving file order.
    private var openGroups: [(section: String?, tasks: [TodoTask])] {
        var groups: [(section: String?, tasks: [TodoTask])] = []
        for t in open {
            if let i = groups.firstIndex(where: { $0.section == t.section }) { groups[i].tasks.append(t) }
            else { groups.append((t.section, [t])) }
        }
        return groups
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(open.isEmpty ? (done.isEmpty ? "No tasks" : "All done")
                              : "\(open.count) open task\(open.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(openGroups.enumerated()), id: \.offset) { _, g in
                        if let s = g.section {
                            Text(s.uppercased()).font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.4)).padding(.top, 3)
                        }
                        ForEach(g.tasks) { t in row(t) }
                    }
                    if !done.isEmpty {
                        if done.count > 5 && !showAllDone {
                            Button { withAnimation(.smooth(duration: 0.2)) { showAllDone = true } } label: {
                                Label("\(done.count) completed", systemImage: "checkmark.circle")
                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                            }
                            .buttonStyle(.plain).padding(.top, 4)
                        } else {
                            Text("COMPLETED").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.35)).padding(.top, 4)
                            ForEach(done) { t in row(t) }
                        }
                    }
                }
            }
        }
    }

    private func row(_ t: TodoTask) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: t.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13)).foregroundStyle(t.done ? Color.green.opacity(0.7) : .white.opacity(0.6))
            Text(t.text).font(.system(size: 12)).lineLimit(2)
                .strikethrough(t.done)
                .foregroundStyle(.white.opacity(t.done ? 0.35 : 0.9))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(t.done ? 0.03 : 0.07)))
        .contentShape(Rectangle())
        .onTapGesture { module.toggle(t) }
    }
}
