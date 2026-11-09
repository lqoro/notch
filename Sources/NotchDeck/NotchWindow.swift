import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Allow the panel to sit over the menu bar / notch region.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel, positions it, and drives hover/drag-based open & close from event monitors
/// (no polling, no timers except one-shot hover delays).
@MainActor
final class NotchWindowController {
    private let state: NotchState
    private let registry: PluginRegistry
    private let settings: AppSettings
    private(set) var panel: NotchPanel!

    private var monitors: [Any] = []
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?

    private static let pad: CGFloat = 24

    init(state: NotchState, registry: PluginRegistry, settings: AppSettings) {
        self.state = state
        self.registry = registry
        self.settings = settings
        buildPanel()
        installMonitors()
        state.onPhaseChange = { [weak self] _ in self?.phaseChanged() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        }
    }

    // MARK: Panel

    private func panelFrame() -> NSRect {
        let g = state.geometry
        let w = NotchState.openWidth + 2 * Self.pad
        let h = g.notchSize.height + NotchState.openContentHeight + Self.pad
        return NSRect(x: g.midX - w / 2, y: g.screenFrame.maxY - h, width: w, height: h)
    }

    private func buildPanel() {
        let frame = panelFrame()
        let p = NotchPanel(contentRect: frame,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true   // closed: let clicks fall through to the menu bar

        let root = NotchRootView(state: state, registry: registry, settings: settings,
                                 canvas: frame.size)
        let host = NotchHostingView(rootView: root)
        host.safeAreaRegions = []
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        p.setFrame(frame, display: false)
        p.orderFrontRegardless()
        panel = p
    }

    private func screenChanged() {
        state.geometry = NotchGeometry.current()
        let frame = panelFrame()
        panel.setFrame(frame, display: true)
        registry.broadcast(.screenChanged)
    }

    private func phaseChanged() {
        panel.ignoresMouseEvents = (state.phase != .open)
    }

    // MARK: Mouse monitoring

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }) { monitors.append(l) }
    }

    private func hoverRect(for phase: NotchState.Phase) -> CGRect {
        let r = state.geometry.rect(for: state.size(for: phase))
        switch phase {
        case .open: return r.insetBy(dx: -14, dy: -14)
        default: return r.insetBy(dx: -4, dy: -6)
        }
    }

    /// Drag pasteboard change count captured at mouse-down; the pasteboard keeps the last drag's
    /// contents forever, so a drag only counts as a file drag if the count changed since.
    private var dragChangeCountAtMouseDown = NSPasteboard(name: .drag).changeCount

    private func isFileDrag() -> Bool {
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragChangeCountAtMouseDown else { return false }
        return pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    private func handle(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            dragChangeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
            // Clicking anywhere outside the open notch collapses it right away.
            if state.phase == .open, !hoverRect(for: .open).contains(NSEvent.mouseLocation),
               !state.isDraggingOut, !state.isDropTargeted {
                cancelClose()
                state.close()
            }
            return
        }
        let p = NSEvent.mouseLocation
        if event.type == .mouseMoved { state.isDraggingOut = false }
        if event.type == .leftMouseUp { state.isDraggingOut = false; state.isDropTargeted = false }

        switch state.phase {
        case .closed, .peek:
            let inside = hoverRect(for: state.phase).contains(p)
            if event.type == .leftMouseDragged {
                // File dragged to the notch: open immediately and show the tray.
                if inside || hoverRect(for: state.phase).insetBy(dx: -30, dy: -30).contains(p), isFileDrag() {
                    cancelOpen()
                    guard settings.isEnabled("filetray") else { return }
                    if let tray = registry.module(id: "filetray") { state.select(tray.id) }
                    state.open()
                }
                return
            }
            if inside { scheduleOpen() } else { cancelOpen() }
        case .open:
            if hoverRect(for: .open).contains(p) || state.isDraggingOut || state.isDropTargeted {
                cancelClose()
            } else if event.type != .leftMouseUp || !state.isDraggingOut {
                scheduleClose()
            }
        }
    }

    private func scheduleOpen() {
        guard openWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.openWork = nil
            if self.hoverRect(for: self.state.phase).contains(NSEvent.mouseLocation) { self.state.open() }
        }
        openWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.hoverDelay, execute: w)
    }

    private func cancelOpen() { openWork?.cancel(); openWork = nil }

    private func scheduleClose() {
        guard closeWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWork = nil
            if !self.hoverRect(for: .open).contains(NSEvent.mouseLocation),
               !self.state.isDraggingOut, !self.state.isDropTargeted {
                self.state.close()
            }
        }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
    }

    private func cancelClose() { closeWork?.cancel(); closeWork = nil }
}
