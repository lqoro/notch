import Foundation

enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("NotchDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

final class AppSettings: ObservableObject {
    private let ud = UserDefaults.standard

    @Published var hoverDelay: Double { didSet { ud.set(hoverDelay, forKey: "hoverDelay") } }
    @Published var disabledModules: Set<String> {
        didSet { ud.set(Array(disabledModules), forKey: "disabledModules") }
    }
    var lastTab: String {
        get { ud.string(forKey: "lastTab") ?? "nowplaying" }
        set { ud.set(newValue, forKey: "lastTab") }
    }

    init() {
        hoverDelay = ud.object(forKey: "hoverDelay") as? Double ?? 0.12
        disabledModules = Set(ud.stringArray(forKey: "disabledModules") ?? [])
    }

    func isEnabled(_ id: String) -> Bool { !disabledModules.contains(id) }

    func setEnabled(_ id: String, _ on: Bool) {
        if on { disabledModules.remove(id) } else { disabledModules.insert(id) }
    }
}
