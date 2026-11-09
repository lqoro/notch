import SwiftUI

enum NotchEvent {
    case opened, closed, screenChanged
}

/// Contract shared by built-in and external modules.
@MainActor
protocol NotchModule: AnyObject {
    var id: String { get }
    var title: String { get }
    /// SF Symbol name.
    var icon: String { get }
    /// Higher = earlier tab / wins the compact slot.
    var priority: Int { get }
    /// Whether the module gets a tab in the open notch.
    var showsTab: Bool { get }
    /// True while the module wants to show something in the closed notch wings.
    var isCompactActive: Bool { get }
    /// Optional badge shown on the tab button (0 = none).
    var badgeCount: Int { get }

    func compactLeading() -> AnyView
    func compactTrailing() -> AnyView
    func expandedView() -> AnyView
    func onEvent(_ event: NotchEvent)
    func start(state: NotchState)
    func stop()
}

extension NotchModule {
    var showsTab: Bool { true }
    var isCompactActive: Bool { false }
    var badgeCount: Int { 0 }
    func compactLeading() -> AnyView { AnyView(EmptyView()) }
    func compactTrailing() -> AnyView { AnyView(EmptyView()) }
    func onEvent(_ event: NotchEvent) {}
    func stop() {}
}

// Namespace used for matchedGeometryEffect between compact and expanded artwork.
private struct NotchNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}
extension EnvironmentValues {
    var notchNamespace: Namespace.ID? {
        get { self[NotchNamespaceKey.self] }
        set { self[NotchNamespaceKey.self] = newValue }
    }
}

struct MatchedArt: ViewModifier {
    @Environment(\.notchNamespace) private var ns
    func body(content: Content) -> some View {
        if let ns { content.matchedGeometryEffect(id: "art", in: ns) } else { content }
    }
}
