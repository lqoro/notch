import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
final class PluginRegistry {
    private(set) var modules: [any NotchModule] = []
    @ObservationIgnored private var running: Set<String> = []
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored weak var state: NotchState?

    static var pluginsDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent("Plugins", isDirectory: true)
    }

    init(settings: AppSettings) { self.settings = settings }

    func register(_ m: any NotchModule) {
        guard !modules.contains(where: { $0.id == m.id }) else { return }
        modules.append(m)
        modules.sort { $0.priority > $1.priority }
    }

    func module(id: String) -> (any NotchModule)? { modules.first { $0.id == id } }

    var tabModules: [any NotchModule] {
        modules.filter { $0.showsTab && settings.isEnabled($0.id) }
    }

    var compactModule: (any NotchModule)? {
        modules.first { settings.isEnabled($0.id) && $0.isCompactActive }
    }

    func registerBuiltIns() {
        register(NowPlayingModule())
        register(FileTrayModule())
        register(HUDModule())
        register(TimerModule())
        register(CalendarModule())
        register(BatteryModule())
        register(NotificationsModule())
        register(TodosModule())
        loadExternalPlugins()
    }

    /// Declarative plugins: ~/Library/Application Support/NotchDeck/Plugins/<name>/manifest.json
    func loadExternalPlugins() {
        let fm = FileManager.default
        let dir = Self.pluginsDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            let manifest = entry.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest),
                  let m = try? JSONDecoder().decode(ManifestModule.Manifest.self, from: data) else { continue }
            register(ManifestModule(manifest: m, directory: entry))
        }
    }

    /// Starts enabled modules and stops disabled ones.
    func applyEnabledState() {
        guard let state else { return }
        for m in modules {
            let enabled = settings.isEnabled(m.id)
            if enabled && !running.contains(m.id) {
                running.insert(m.id)
                m.start(state: state)
            } else if !enabled && running.contains(m.id) {
                running.remove(m.id)
                m.stop()
            }
        }
        if !tabModules.contains(where: { $0.id == state.selectedModuleID }), let first = tabModules.first {
            state.select(first.id)
        }
    }

    func broadcast(_ e: NotchEvent) {
        for m in modules where running.contains(m.id) { m.onEvent(e) }
    }
}
