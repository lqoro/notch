import SwiftUI
import AppKit

/// A declarative external plugin loaded from a manifest.json (no executable code is loaded).
@MainActor
final class ManifestModule: NotchModule {
    struct Button: Codable, Hashable {
        var label: String
        var symbol: String?
        var url: String          // https:// URL, file path, or app path
    }
    struct Manifest: Codable {
        var id: String
        var title: String
        var icon: String?
        var priority: Int?
        var text: String?
        var buttons: [Button]?
    }

    let manifest: Manifest
    let directory: URL
    var id: String { "plugin." + manifest.id }
    var title: String { manifest.title }
    var icon: String { manifest.icon ?? "puzzlepiece.extension" }
    var priority: Int { manifest.priority ?? 0 }

    init(manifest: Manifest, directory: URL) {
        self.manifest = manifest
        self.directory = directory
    }

    func start(state: NotchState) {}

    func expandedView() -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 12) {
            if let t = manifest.text {
                Text(t).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
            }
            HStack {
                ForEach(manifest.buttons ?? [], id: \.self) { b in
                    SwiftUI.Button {
                        if let u = URL(string: b.url), u.scheme != nil { NSWorkspace.shared.open(u) }
                        else { NSWorkspace.shared.open(URL(fileURLWithPath: (b.url as NSString).expandingTildeInPath)) }
                    } label: {
                        Label(b.label, systemImage: b.symbol ?? "arrow.up.right")
                    }.buttonStyle(.bordered)
                }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading))
    }
}
