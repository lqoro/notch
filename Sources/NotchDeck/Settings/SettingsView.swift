import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let registry: PluginRegistry
    @StateObject private var launchBox = Local(SMAppService.mainApp.status == .enabled)
    @StateObject private var errorBox = Local<String?>(nil)
    private var launchAtLogin: Bool { get { launchBox.value } nonmutating set { launchBox.value = newValue } }
    private var loginError: String? { get { errorBox.value } nonmutating set { errorBox.value = newValue } }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunch))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                HStack {
                    Text("Hover delay")
                    Slider(value: $settings.hoverDelay, in: 0...0.6)
                    Text(String(format: "%.2fs", settings.hoverDelay)).monospacedDigit().frame(width: 48)
                }
            }
            Section("Modules") {
                ForEach(registry.modules, id: \.id) { m in
                    Toggle(isOn: Binding(get: { settings.isEnabled(m.id) }, set: { on in
                        settings.setEnabled(m.id, on)
                        registry.applyEnabledState()
                    })) {
                        Label(m.title, systemImage: m.icon)
                    }
                }
            }
            Section("Permissions") {
                if let hud = registry.module(id: "hud") as? HUDModule {
                    HStack {
                        Text(hud.hasAccessibility ? "Accessibility: granted (media-key HUD on)" : "Accessibility: needed for media-key HUD")
                        Spacer()
                        if !hud.hasAccessibility {
                            Button("Grant") { hud.requestAccessibility() }
                        } else if !hud.tapActive {
                            Button("Retry") { hud.installTap() }
                        }
                    }
                    Text(DisplayBrightness.isAvailable ? "Brightness control available." : "Brightness control unavailable on this system; brightness keys use the stock HUD.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Music/Spotify control asks for Automation permission the first time a player is used. Calendar asks when you tap Allow in the Calendar tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let n = registry.module(id: "notifications") as? NotificationsModule {
                Section("Notifications") {
                    Toggle("Only apps not installed on this Mac (likely iPhone)", isOn: Binding(
                        get: { n.onlyUninstalledApps }, set: { n.onlyUninstalledApps = $0 }))
                    Text("macOS does not record which device a notification came from, so by default all notifications are shown. This toggle is a heuristic and hides iPhone alerts from apps that also exist on the Mac (Messages, Mail...). Needs Full Disk Access; clearing only hides items inside NotchDeck.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Full Disk Access Settings") { n.openFullDiskAccessSettings() }
                }
            }
            if let t = registry.module(id: "todos") as? TodosModule {
                Section("Todos") {
                    TextField("Todo file path", text: Binding(get: { t.filePath }, set: { t.filePath = $0 }))
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Choose file...") { t.chooseFile() }
                        Button("Reset to default") { t.filePath = TodosModule.defaultPath }
                    }
                    Text("Markdown task lists, bullets and headings, or a .json array. NotchDeck only reads this file; ticking a task hides it locally.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Plugins") {
                Text("Drop a folder with manifest.json into ~/Library/Application Support/NotchDeck/Plugins, then relaunch.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Plugins Folder") {
                    try? FileManager.default.createDirectory(at: PluginRegistry.pluginsDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(PluginRegistry.pluginsDirectory)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
    }

    private func setLaunch(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not change login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    var settings: AppSettings?
    var registry: PluginRegistry?
    private var window: NSWindow?

    func show() {
        guard let settings, let registry else { return }
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings, registry: registry)))
            w.title = "NotchDeck Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
