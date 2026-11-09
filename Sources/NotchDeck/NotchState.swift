import AppKit
import SwiftUI
import Observation

/// A short-lived message shown in the notch wings (volume, brightness, battery, timer...).
struct Transient: Equatable {
    var icon: String
    var label: String
    var value: Double?      // 0...1 draws a bar
    var tint: Color = .white
}

@MainActor
@Observable
final class NotchState {
    enum Phase { case closed, peek, open }

    static let closedTopRadius: CGFloat = 6
    static let openWidth: CGFloat = 620
    static let openContentHeight: CGFloat = 168
    static let compactWing: CGFloat = 40
    static let peekWing: CGFloat = 104
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.78)
    /// Used when collapsing: quick and well damped so it snaps back into the notch.
    static let closeSpring = Animation.spring(response: 0.22, dampingFraction: 0.9)

    private(set) var phase: Phase = .closed
    var geometry: NotchGeometry
    var transient: Transient?
    var isDropTargeted = false
    @ObservationIgnored var isDraggingOut = false
    @ObservationIgnored weak var registry: PluginRegistry?
    @ObservationIgnored var settings: AppSettings
    @ObservationIgnored var onPhaseChange: ((Phase) -> Void)?
    @ObservationIgnored private var hideWork: DispatchWorkItem?

    var selectedModuleID: String

    init(geometry: NotchGeometry, settings: AppSettings) {
        self.geometry = geometry
        self.settings = settings
        self.selectedModuleID = settings.lastTab
    }

    func size(for phase: Phase) -> CGSize {
        let g = geometry
        let base = g.notchSize.width + 2 * Self.closedTopRadius
        switch phase {
        case .closed:
            let extra = (registry?.compactModule != nil) ? 2 * Self.compactWing : 0
            return CGSize(width: base + extra, height: g.notchSize.height)
        case .peek:
            return CGSize(width: base + 2 * Self.peekWing, height: g.notchSize.height)
        case .open:
            return CGSize(width: Self.openWidth, height: g.notchSize.height + Self.openContentHeight)
        }
    }

    func setPhase(_ new: Phase) {
        guard new != phase else { return }
        let old = phase
        withAnimation(new == .open ? Self.spring : Self.closeSpring) { phase = new }
        if new == .open { cancelHide(); transient = nil }
        onPhaseChange?(new)
        if old == .open { registry?.broadcast(.closed) }
        if new == .open { registry?.broadcast(.opened) }
    }

    func open() { setPhase(.open) }
    func close() { setPhase(.closed) }

    func select(_ id: String) {
        selectedModuleID = id
        settings.lastTab = id
    }

    /// Briefly expand the closed notch to show a message. Ignored while fully open.
    func showTransient(_ t: Transient, duration: TimeInterval = 1.6) {
        guard phase != .open else { return }
        cancelHide()
        withAnimation(.smooth(duration: 0.18)) { transient = t }
        setPhase(.peek)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .peek else { return }
            self.setPhase(.closed)
            self.transient = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func cancelHide() { hideWork?.cancel(); hideWork = nil }
}
