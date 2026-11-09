import SwiftUI
import AppKit
import SQLite3
import Observation

// MARK: - Model

struct NotifItem: Identifiable, Equatable {
    let id: String          // record uuid (hex) or rec_id
    let appID: String
    let appName: String
    let title: String
    let subtitle: String
    let body: String
    let date: Date
    let installedOnMac: Bool
}

struct RawNotifRow: Sendable {
    let id: String
    let appID: String
    let data: Data
    let date: Double        // Core Data reference-date seconds
}

enum NotifReadResult: Sendable {
    case ok([RawNotifRow])
    case needsAccess
    case missing
    case failure(String)
}

// MARK: - Database reader (read-only; never writes to the Notification Center db)

enum NotificationDB {
    static var directory: String {
        NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2"
    }
    static var dbPath: String { directory + "/db" }
    static let fetchLimit = 80

    static func read() -> NotifReadResult {
        // Full Disk Access probe: EPERM/EACCES means TCC is blocking us.
        let fd = open(dbPath, O_RDONLY)
        if fd < 0 {
            switch errno {
            case ENOENT, ENOTDIR: return .missing
            case EPERM, EACCES: return .needsAccess
            default: return .failure(String(cString: strerror(errno)))
            }
        }
        close(fd)

        let direct = query(path: dbPath)
        if case .ok = direct { return direct }
        if case .failure = direct {
            // Locked / WAL trouble: fall back to querying a private copy of the files (originals only read).
            if let copied = queryCopy() { return copied }
        }
        return direct
    }

    private static func queryCopy() -> NotifReadResult? {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("NotchDeckNotif-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: tmp)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let src = URL(fileURLWithPath: dbPath + suffix)
                if fm.fileExists(atPath: src.path) {
                    try fm.copyItem(at: src, to: tmp.appendingPathComponent("db" + suffix))
                }
            }
        } catch { try? fm.removeItem(at: tmp); return nil }
        defer { try? fm.removeItem(at: tmp) }
        return query(path: tmp.appendingPathComponent("db").path)
    }

    private static func query(path: String) -> NotifReadResult {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        defer { if let db { sqlite3_close(db) } }
        guard rc == SQLITE_OK, let db else {
            if rc == SQLITE_AUTH || rc == SQLITE_PERM { return .needsAccess }
            return .failure("Could not open database (\(rc))")
        }
        sqlite3_busy_timeout(db, 300)
        _ = sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil)

        let recordCols = columns(db, "record")
        let appCols = columns(db, "app")
        guard recordCols.contains("data"), recordCols.contains("app_id") else {
            return .failure("Unsupported database schema")
        }
        let dateCol = ["delivered_date", "request_date", "request_last_date"].first { recordCols.contains($0) } ?? "rec_id"
        let idExpr = recordCols.contains("uuid") ? "hex(r.uuid)" : "CAST(r.rec_id AS TEXT)"
        let hasApp = appCols.contains("app_id") && appCols.contains("identifier")
        let appExpr = hasApp ? "a.identifier" : "NULL"
        let join = hasApp ? "LEFT JOIN app a ON a.app_id = r.app_id" : ""
        let sql = "SELECT \(idExpr), \(appExpr), r.data, r.\(dateCol) FROM record r \(join) ORDER BY r.\(dateCol) DESC LIMIT \(fetchLimit)"

        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt else {
            if prep == SQLITE_AUTH || prep == SQLITE_PERM { return .needsAccess }
            return .failure(prep == SQLITE_BUSY || prep == SQLITE_LOCKED ? "Database is locked" : "Query failed (\(prep))")
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [RawNotifRow] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? UUID().uuidString
                let app = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                var data = Data()
                if let p = sqlite3_column_blob(stmt, 2) {
                    data = Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, 2)))
                }
                let date = sqlite3_column_double(stmt, 3)
                rows.append(RawNotifRow(id: id, appID: app, data: data, date: date))
            } else if step == SQLITE_DONE {
                break
            } else {
                if rows.isEmpty { return .failure(step == SQLITE_BUSY || step == SQLITE_LOCKED ? "Database is locked" : "Read failed (\(step))") }
                break
            }
        }
        return .ok(rows)
    }

    private static func columns(_ db: OpaquePointer, _ table: String) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) { out.insert(String(cString: c)) }
        }
        return out
    }

    /// Pulls title/subtitle/body/date out of a record's binary plist. Tolerates missing keys.
    static func parse(_ row: RawNotifRow) -> (title: String, subtitle: String, body: String, date: Date, appID: String)? {
        guard !row.data.isEmpty,
              let obj = try? PropertyListSerialization.propertyList(from: row.data, options: [], format: nil),
              let root = obj as? [String: Any] else { return nil }
        let req = root["req"] as? [String: Any] ?? [:]
        func str(_ k: String) -> String { (req[k] as? String) ?? "" }
        var ref = row.date
        if ref <= 0, let d = root["date"] as? Double { ref = d }
        let appID = !row.appID.isEmpty ? row.appID : ((root["app"] as? String) ?? "")
        return (str("titl"), str("subt"), str("body"), Date(timeIntervalSinceReferenceDate: ref), appID)
    }
}

// MARK: - Module

@MainActor
@Observable
final class NotificationsModule: NotchModule {
    enum Status: Equatable { case loading, ready, needsAccess, missing, failure(String) }

    let id = "notifications"
    let title = "Notifications"
    let icon = "bell.badge"
    let priority = 45

    private(set) var items: [NotifItem] = []
    private(set) var status: Status = .loading
    private(set) var dismissed: [String]

    /// Settings toggle: only show apps that are not installed on this Mac (a heuristic for iPhone-originated).
    var onlyUninstalledApps: Bool {
        didSet { UserDefaults.standard.set(onlyUninstalledApps, forKey: Self.onlyKey); rebuildVisible() }
    }

    var badgeCount: Int { items.count }

    @ObservationIgnored private var all: [NotifItem] = []
    @ObservationIgnored private weak var state: NotchState?
    @ObservationIgnored private var sources: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var debounce: DispatchWorkItem?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastSeenDate: Date?
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored private var nameCache: [String: (String, Bool)] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "notchdeck.notifications.read", qos: .utility)

    private static let onlyKey = "notifications.onlyUninstalled"
    private static let dismissedKey = "notifications.dismissed"
    private static let maxDismissed = 600

    init() {
        let ud = UserDefaults.standard
        onlyUninstalledApps = ud.bool(forKey: Self.onlyKey)
        dismissed = ud.stringArray(forKey: Self.dismissedKey) ?? []
    }

    // MARK: Lifecycle

    func start(state: NotchState) {
        self.state = state
        lastSeenDate = nil
        reload()
        startWatching()
    }

    func stop() {
        stopWatching()
        debounce?.cancel(); debounce = nil
        generation += 1
    }

    func onEvent(_ event: NotchEvent) {
        // Retry once per open if we could not read or watch the db earlier.
        if event == .opened, status != .ready || sources.isEmpty {
            reload()
            if sources.isEmpty { startWatching() }
        }
    }

    func expandedView() -> AnyView { AnyView(NotificationsView(module: self)) }

    // MARK: Watching (event-driven; no polling)

    private func startWatching() {
        stopWatching()
        let dir = NotificationDB.directory
        for path in [NotificationDB.dbPath, NotificationDB.dbPath + "-wal", dir] {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
            src.setEventHandler { [weak self, weak src] in
                let flags = src?.data ?? []
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scheduleReload()
                    if flags.contains(.delete) || flags.contains(.rename) {
                        // File replaced: re-arm on the new inode after the debounce.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                            MainActor.assumeIsolated { self?.startWatching() }
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
        queue.async { [weak self] in
            let result = NotificationDB.read()
            var parsed: [(RawNotifRow, (title: String, subtitle: String, body: String, date: Date, appID: String))] = []
            if case .ok(let rows) = result {
                for r in rows { if let p = NotificationDB.parse(r) { parsed.append((r, p)) } }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(result: result, parsed: parsed, generation: gen) }
            }
        }
    }

    private func apply(result: NotifReadResult,
                       parsed: [(RawNotifRow, (title: String, subtitle: String, body: String, date: Date, appID: String))],
                       generation gen: Int) {
        guard gen == generation else { return }
        switch result {
        case .needsAccess: status = .needsAccess; all = []; items = []; return
        case .missing: status = .missing; all = []; items = []; return
        case .failure(let m): status = .failure(m); return   // keep last good list
        case .ok: break
        }
        let selfID = Bundle.main.bundleIdentifier ?? "NotchDeck"
        var built: [NotifItem] = []
        for (raw, p) in parsed {
            guard !p.appID.isEmpty, !p.appID.hasPrefix(selfID) else { continue }
            let (name, installed) = appInfo(p.appID)
            built.append(NotifItem(id: raw.id, appID: p.appID, appName: name, title: p.title,
                                   subtitle: p.subtitle, body: p.body, date: p.date, installedOnMac: installed))
        }
        built.sort { $0.date > $1.date }
        all = built
        status = .ready

        // Peek for notifications newer than anything seen before (not on the first load).
        let visible = visibleList()
        let newest = built.first?.date
        if let last = lastSeenDate {
            let fresh = visible.filter { $0.date > last }
            if let first = fresh.first {
                let label = fresh.count > 1 ? "\(first.appName) +\(fresh.count - 1)" : first.appName
                state?.showTransient(Transient(icon: "bell.badge.fill", label: label, value: nil, tint: .yellow), duration: 4)
            }
        }
        if let newest { lastSeenDate = max(newest, lastSeenDate ?? newest) } else if lastSeenDate == nil { lastSeenDate = .distantPast }
        items = visible
    }

    private func visibleList() -> [NotifItem] {
        let gone = Set(dismissed)
        return Array(all.lazy
            .filter { !gone.contains($0.id) }
            .filter { !self.onlyUninstalledApps || !$0.installedOnMac }
            .prefix(30))
    }

    private func rebuildVisible() { items = visibleList() }

    // MARK: App resolution

    private func appInfo(_ bundleID: String) -> (String, Bool) {
        if let c = nameCache[bundleID] { return c }
        var result: (String, Bool)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            result = (name, true)
        } else {
            let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            result = (last.prefix(1).uppercased() + last.dropFirst(), false)
        }
        nameCache[bundleID] = result
        return result
    }

    func appIcon(_ bundleID: String) -> NSImage? {
        if let i = iconCache[bundleID] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = img
        return img
    }

    // MARK: Dismissal (local only; the real database is never modified)

    func dismiss(_ item: NotifItem) { dismiss(ids: [item.id]) }
    func dismissAll() { dismiss(ids: items.map(\.id)) }

    private func dismiss(ids: [String]) {
        for i in ids where !dismissed.contains(i) { dismissed.append(i) }
        if dismissed.count > Self.maxDismissed { dismissed.removeFirst(dismissed.count - Self.maxDismissed) }
        UserDefaults.standard.set(dismissed, forKey: Self.dismissedKey)
        withAnimation(.smooth(duration: 0.2)) { rebuildVisible() }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - View

struct NotificationsView: View {
    let module: NotificationsModule

    var body: some View {
        switch module.status {
        case .needsAccess: accessState
        case .missing: message("bell.slash", "Notification database not found.")
        case .failure(let m) where module.items.isEmpty: message("exclamationmark.triangle", "Can't read notifications: \(m)")
        case .loading where module.items.isEmpty: message("bell", "Loading...")
        default: list
        }
    }

    private var accessState: some View {
        HStack(spacing: 18) {
            Image(systemName: "lock.shield").font(.system(size: 28)).foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 6) {
                Text("Full Disk Access needed").font(.system(size: 14, weight: .semibold))
                Text("Add NotchDeck.app under Privacy & Security > Full Disk Access, then quit and reopen NotchDeck.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                HStack {
                    Button("Grant Full Disk Access") { module.openFullDiskAccessSettings() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Retry") { module.reload() }.buttonStyle(.bordered).controlSize(.small)
                }
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

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(module.items.isEmpty ? "No notifications" : "\(module.items.count) notification\(module.items.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                if !module.items.isEmpty {
                    Button("Clear all") { module.dismissAll() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(module.items) { item in
                        NotificationRow(item: item, icon: module.appIcon(item.appID))
                            .onTapGesture { module.dismiss(item) }
                    }
                }
            }
        }
    }
}

struct NotificationRow: View {
    let item: NotifItem
    let icon: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: "app.badge").resizable().scaledToFit().padding(3).foregroundStyle(.white.opacity(0.6)) }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.appName.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                    Text(item.date, style: .relative).font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
                }
                if !item.title.isEmpty {
                    Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                let detail = [item.subtitle, item.body].filter { !$0.isEmpty }.joined(separator: " - ")
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Hairline outline instead of a gray fill, so the card interior stays true black.
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .contentShape(Rectangle())
    }
}
