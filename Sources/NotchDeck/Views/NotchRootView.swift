import SwiftUI
import UniformTypeIdentifiers

struct NotchRootView: View {
    let state: NotchState
    let registry: PluginRegistry
    @ObservedObject var settings: AppSettings
    let canvas: CGSize
    @Namespace private var ns

    private var isOpen: Bool { state.phase == .open }

    var body: some View {
        let size = state.size(for: state.phase)
        let topR: CGFloat = isOpen ? 19 : NotchState.closedTopRadius
        let botR: CGFloat = isOpen ? 26 : (state.phase == .peek ? 14 : 12)
        let notchH = state.geometry.notchSize.height

        ZStack(alignment: .top) {
            NotchShape(topRadius: topR, bottomRadius: botR)
                // Exact (0,0,0) black with no shadow halo: lets the display switch those backlight
                // zones fully off so the panel melts into the hardware notch and bezel.
                .fill(Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1))
                .frame(width: size.width, height: size.height)

            ZStack(alignment: .top) {
                switch state.phase {
                case .closed: closedContent(notchH: notchH, topR: topR)
                case .peek: peekContent(notchH: notchH, topR: topR)
                case .open: openContent(notchH: notchH, topR: topR)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(NotchShape(topRadius: topR, bottomRadius: botR))

            if state.isDropTargeted {
                NotchShape(topRadius: topR, bottomRadius: botR)
                    .stroke(Color.accentColor.opacity(0.9), lineWidth: 2)
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .top)
        .environment(\.notchNamespace, ns)
        .animation(state.phase == .open ? NotchState.spring : NotchState.closeSpring, value: state.phase)
        .animation(state.phase == .open ? NotchState.spring : NotchState.closeSpring, value: size.width)
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { state.isDropTargeted },
                                                    set: { state.isDropTargeted = $0 })) { providers in
            guard settings.isEnabled("filetray"),
                  let tray = registry.module(id: "filetray") as? FileTrayModule else { return false }
            tray.add(providers: providers)
            state.select(tray.id)
            return true
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Closed

    @ViewBuilder
    private func closedContent(notchH: CGFloat, topR: CGFloat) -> some View {
        if let m = registry.compactModule {
            HStack(spacing: 0) {
                m.compactLeading().frame(width: NotchState.compactWing)
                Spacer(minLength: 0)
                m.compactTrailing().frame(width: NotchState.compactWing)
            }
            .padding(.horizontal, topR)
            .frame(height: notchH)
            .transition(.opacity)
        }
    }

    // MARK: Peek

    @ViewBuilder
    private func peekContent(notchH: CGFloat, topR: CGFloat) -> some View {
        if let t = state.transient {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: t.icon).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(t.tint)
                    Text(t.label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(.white)
                }
                .frame(width: NotchState.peekWing, alignment: .leading)
                .padding(.leading, 10)
                Spacer(minLength: 0)
                Group {
                    if let v = t.value {
                        ProgressBar(value: v, tint: t.tint)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: NotchState.peekWing - 14, alignment: .trailing)
                .padding(.trailing, 10)
            }
            .padding(.horizontal, topR)
            .frame(height: notchH)
            .transition(.opacity)
        }
    }

    // MARK: Open

    @ViewBuilder
    private func openContent(notchH: CGFloat, topR _: CGFloat) -> some View {
        let tabs = registry.tabModules
        let selected = tabs.first { $0.id == state.selectedModuleID } ?? tabs.first
        // Split the tabs around the hardware notch so none of them end up hidden behind it:
        // the first half sits left of the notch, the rest (plus Settings) right of it.
        let leftCount = (tabs.count + 2) / 2
        let leftTabs = Array(tabs.prefix(leftCount))
        let rightTabs = Array(tabs.dropFirst(leftCount))
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach(leftTabs, id: \.id) { m in
                        TabButton(icon: m.icon, title: m.title, selected: m.id == selected?.id, badge: m.badgeCount) {
                            state.select(m.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 8)
                Color.clear.frame(width: state.geometry.notchSize.width)
                HStack(spacing: 2) {
                    ForEach(rightTabs, id: \.id) { m in
                        TabButton(icon: m.icon, title: m.title, selected: m.id == selected?.id, badge: m.badgeCount) {
                            state.select(m.id)
                        }
                    }
                    Spacer(minLength: 4)
                    TabButton(icon: "gearshape", title: "Settings", selected: false) {
                        SettingsWindowController.shared.show()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
            }
            .padding(.horizontal, 24)
            .frame(height: notchH)

            Group {
                if let selected {
                    selected.expandedView().id(selected.id)
                } else {
                    Text("No modules enabled").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 38)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .transition(.opacity)
        }
    }
}

struct TabButton: View {
    let icon: String
    let title: String
    let selected: Bool
    var badge: Int = 0
    let action: () -> Void
    @StateObject private var hoverBox = Local(false)
    private var hover: Bool { hoverBox.value }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.5))
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(selected ? 0.18 : (hover ? 0.08 : 0))))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 9 ? "9+" : "\(badge)")
                            .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 3).frame(minWidth: 11, minHeight: 11)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 4, y: -3)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(title)
        .onHover { hoverBox.value = $0 }
    }
}

struct ProgressBar: View {
    let value: Double
    var tint: Color = .white
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(tint).frame(width: max(4, g.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}
