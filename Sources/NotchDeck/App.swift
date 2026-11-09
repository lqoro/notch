import AppKit
import SwiftUI
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var state: NotchState!
    private var registry: PluginRegistry!
    private var windowController: NotchWindowController!
    private var statusItem: NSStatusItem!
    // Sparkle only starts when the build embeds an update key (release builds); dev builds skip it.
    private let updater = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil,
        updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = AppSettings()
        state = NotchState(geometry: NotchGeometry.current(), settings: settings)
        registry = PluginRegistry(settings: settings)
        registry.state = state
        state.registry = registry
        registry.registerBuiltIns()

        SettingsWindowController.shared.settings = settings
        SettingsWindowController.shared.registry = registry

        windowController = NotchWindowController(state: state, registry: registry, settings: settings)
        registry.applyEnabledState()
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                           accessibilityDescription: "NotchDeck")
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        let check = menu.addItem(withTitle: "Check for Updates…",
                                 action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        check.target = updater
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NotchDeck", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}

@main
enum NotchDeckMain {
    @MainActor static var delegate: AppDelegate?

    @MainActor static func main() {
        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
